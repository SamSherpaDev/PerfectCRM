require "test_helper"

# Fake IMAP server for sync tests: records which read-only methods were
# called and raises if the fetcher ever tries a write (select/store/copy).
class FakeImap
  attr_reader :calls, :folders

  Row = Struct.new(:attr)

  def initialize(messages: {}, uid_validity: 12345)
    @messages = messages # uid => { raw:, thrid:, msgid:, labels: }
    @uid_validity = uid_validity
    @calls = []
    @responses = { "UIDVALIDITY" => [ uid_validity ] }
  end

  def responses
    @responses
  end

  def examine(folder)
    @calls << [ :examine, folder ]
    true
  end

  def status(folder, keys)
    @calls << [ :status, folder, keys ]
    { "UIDVALIDITY" => @uid_validity }
  end

  def uid_search(criteria)
    @calls << [ :uid_search, criteria ]
    @messages.keys.sort
  end

  def uid_fetch(uids, items)
    @calls << [ :uid_fetch, uids, items ]
    Array(uids).filter_map do |uid|
      data = @messages[uid]
      next if data.nil?

      Row.new({
        "RFC822" => data[:raw],
        "X-GM-THRID" => data[:thrid],
        "X-GM-MSGID" => data[:msgid],
        "X-GM-LABELS" => data[:labels] || []
      })
    end
  end

  def logout; end
  def disconnect; end

  # Write methods must never be called: fail loudly if they are.
  %i[select store copy move expunge uid_store uid_copy uid_move].each do |name|
    define_method(name) { |*| raise "read-only violation: #{name} called" }
  end
end

def sync_raw(from:, to: "info@sherpaholidays.com", subject: "Hi", message_id:)
  "From: #{from}\r\nTo: #{to}\r\nSubject: #{subject}\r\nMessage-ID: #{message_id}\r\nDate: Mon, 14 Sep 2026 10:00:00 -0700\r\n\r\nbody"
end

class MailSyncJobTest < ActiveSupport::TestCase
  setup do
    Setting.current.update!(mailbox_login: "captain@gmail.com", mailbox_app_password: "xxxx-xxxx")
  end

  test "incremental sync stores new mail and advances the cursor" do
    imap = FakeImap.new(messages: {
      10 => { raw: sync_raw(from: "a@example.com", message_id: "<a@test>"), thrid: "t-a", msgid: "101" },
      11 => { raw: sync_raw(from: "b@example.com", message_id: "<b@test>"), thrid: "t-b", msgid: "102" }
    })
    assert_difference("Message.count", 2) do
      Mail::SyncJob.new.perform(fetcher: Mail::ImapFetcher.new(login: "x", password: "y", imap: imap))
    end
    assert_equal 11, MailSyncState.for(Mail::FOLDER).last_uid

    imap2 = FakeImap.new(messages: {
      10 => { raw: sync_raw(from: "a@example.com", message_id: "<a@test>"), thrid: "t-a", msgid: "101" },
      11 => { raw: sync_raw(from: "b@example.com", message_id: "<b@test>"), thrid: "t-b", msgid: "102" },
      12 => { raw: sync_raw(from: "c@example.com", message_id: "<c@test>"), thrid: "t-c", msgid: "103" }
    })
    # New fetcher sees the stored cursor and only fetches UID 12+.
    def imap2.uid_search(criteria)
      @calls << [ :uid_search, criteria ]
      [ 12 ]
    end
    assert_difference("Message.count", 1) do
      Mail::SyncJob.new.perform(fetcher: Mail::ImapFetcher.new(login: "x", password: "y", imap: imap2))
    end
  end

  test "personal mail is skipped without storing and read-only is kept" do
    imap = FakeImap.new(messages: {
      20 => { raw: sync_raw(from: "friend@gmail.com", to: "captain@gmail.com", message_id: "<priv@test>"), thrid: "t-p", msgid: "201" }
    })
    assert_no_difference([ "Conversation.count", "Message.count" ]) do
      Mail::SyncJob.new.perform(fetcher: Mail::ImapFetcher.new(login: "x", password: "y", imap: imap))
    end
    names = imap.calls.map(&:first)
    assert_includes names, :examine
    assert_not_includes names, :select
    assert_not_includes names, :store
  end

  test "uidvalidity change resets the cursor" do
    MailSyncState.for(Mail::FOLDER).update!(uid_validity: 111, last_uid: 50)
    imap = FakeImap.new(messages: {
      1 => { raw: sync_raw(from: "a@example.com", message_id: "<reset@test>"), thrid: "t-r", msgid: "301" }
    }, uid_validity: 222)
    Mail::SyncJob.new.perform(fetcher: Mail::ImapFetcher.new(login: "x", password: "y", imap: imap))
    assert_equal 222, MailSyncState.for(Mail::FOLDER).uid_validity
  end

  test "ingestion failure advances only completed UIDs and resumes" do
    imap = FakeImap.new(messages: {
      101 => { raw: sync_raw(from: "one@example.com", message_id: "<checkpoint-one@test>") },
      102 => { raw: sync_raw(from: "two@example.com", message_id: "<checkpoint-two@test>") }
    })
    fetcher = Mail::ImapFetcher.new(login: "x", password: "y", imap: imap)
    original = Mail::Ingester.method(:ingest)
    failing = ->(**args) do
      raise "interrupted" if args[:parsed].from_addresses == [ "two@example.com" ]
      original.call(**args)
    end
    Mail::Ingester.stub(:ingest, failing) do
      assert_raises(RuntimeError) { Mail::SyncJob.new.perform(fetcher: fetcher) }
    end
    assert_equal 101, MailSyncState.for(Mail::FOLDER).last_uid
    assert_difference("Message.count", 1) { Mail::SyncJob.new.perform(fetcher: fetcher) }
    assert_equal 102, MailSyncState.for(Mail::FOLDER).last_uid
  end

  test "connection errors are normalized for settings and history" do
    imap = FakeImap.new
    def imap.status(*)
      raise Net::IMAP::Error, "bad credentials"
    end
    def imap.examine(*)
      raise Net::IMAP::Error, "bad credentials"
    end
    fetcher = Mail::ImapFetcher.new(login: "x", password: "y", imap: imap)
    assert_raises(Mail::ImapFetcher::ConnectionError) { fetcher.test_connection }
    assert_raises(Mail::ImapFetcher::ConnectionError) { fetcher.fetch_all.to_a }
  end

end
