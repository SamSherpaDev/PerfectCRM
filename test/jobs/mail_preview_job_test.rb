require "test_helper"
require_relative "mail_sync_job_test"

class MailPreviewJobTest < ActiveSupport::TestCase
  test "fallback preview counts beyond 2000 messages and resumes after failure" do
    messages = (1..2000).to_h do |uid|
      [ uid, { raw: sync_raw(from: "friend@gmail.com", to: "captain@gmail.com", message_id: "<private#{uid}@test>") } ]
    end
    messages[2001] = { raw: sync_raw(from: "client@example.com", message_id: "<business@test>") }
    messages[2002] = { raw: sync_raw(from: "info@sherpaholidays.com", to: "outbound@example.com", message_id: "<outbound@test>") }
    imap = FakeImap.new(messages: messages)
    def imap.uid_search(criteria)
      @calls << [ :uid_search, criteria ]
      raise Net::IMAP::Error, "unsupported" if criteria.include?("HEADER")
      @messages.keys.sort
    end
    def imap.uid_fetch(uids, items)
      raise IOError, "interrupted" if uids == [ 2002 ] && !@resumed
      super
    end
    import = MailImport.create!(scope: "all", status: "draft")
    fetcher = Mail::ImapFetcher.new(login: "x", password: "y", imap: imap)
    assert_raises(Mail::ImapFetcher::ConnectionError) { Mail::PreviewJob.new.perform(import.id, fetcher: fetcher) }
    assert_equal 2001, import.reload.preview_json["preview_uid"]
    assert_equal 1, import.total_messages
    imap.instance_variable_set(:@resumed, true)
    messages.delete(1)
    Mail::PreviewJob.new.perform(import.id, fetcher: fetcher)
    assert_equal "preview", import.reload.status
    assert_equal 2, import.total_messages
    assert_equal %w[client@example.com outbound@example.com], import.preview_rows.map { |row| row["email"] }.sort
  end
end
