require "test_helper"
require_relative "../support/graph_fake"

def sync_message(id:, from:, to: "info@sherpaholidays.com", message_id: nil, conversation: "sync-conv", received: nil)
  GraphMessageBuilder.instance_method(:graph_message).bind_call(
    Object.new.extend(GraphMessageBuilder),
    id: id, from: from, to: to, subject: "Hi",
    message_id: message_id || "<#{id}@test>", conversation: conversation, received: received)
end

class MailSyncJobTest < ActiveSupport::TestCase
  include GraphMessageBuilder

  setup do
    @mailbox = FakeMailbox.new
    Setting.current.update!(ms_graph_refresh_token: "refresh-0", mailbox_watched_since: Time.current.change(usec: 0),
      mailbox_last_error: nil, mailbox_last_error_at: nil, mailbox_last_sync_at: nil)
  end

  def fetcher
    Mail::GraphFetcher.new(transport: @mailbox.transport)
  end

  def inbox_delta_calls
    @mailbox.requests.count { |request| request.url.include?("mailFolders/inbox/messages/delta") }
  end

  test "first connect stores nothing and later mail syncs incrementally" do
    @mailbox.add("inbox", sync_message(id: "old", from: "old@example.com", received: 1.day.ago.utc.iso8601))
    assert_no_difference([ "Conversation.count", "Message.count" ]) do
      Mail::SyncJob.new.perform(fetcher: fetcher)
    end

    @mailbox.add("inbox", sync_message(id: "new-a", from: "a@example.com"))
    @mailbox.add("sentitems", { **sync_message(id: "new-b", from: "info@sherpaholidays.com",
      to: "a@example.com"), "conversationId" => "other-conv" })
    assert_difference("Message.count", 2) do
      assert_equal 2, Mail::SyncJob.new.perform(fetcher: fetcher)
    end
    assert Setting.current.reload.mailbox_last_sync_at.present?

    assert_no_difference("Message.count") do
      assert_equal 0, Mail::SyncJob.new.perform(fetcher: fetcher)
    end
  end

  test "personal mail is skipped without storing and access stays read-only" do
    Mail::SyncJob.new.perform(fetcher: fetcher) # prime
    @mailbox.add("inbox", sync_message(id: "priv", from: "friend@gmail.com", to: "captain@gmail.com"))

    assert_no_difference([ "Conversation.count", "Message.count" ]) do
      Mail::SyncJob.new.perform(fetcher: fetcher)
    end
    methods = @mailbox.requests.map(&:method).uniq
    assert_includes methods, :get
    @mailbox.requests.each { |request| assert_includes [ :get, :get_bytes, :post ], request.method }
  end

  test "app mail from the mailbox to itself is skipped while client mail still syncs" do
    Mail::SyncJob.new.perform(fetcher: fetcher) # prime
    @mailbox.add("inbox", { **graph_message(id: "self", from: "INFO@sherpaholidays.com",
      to: "info@sherpaholidays.com", subject: "PerfectBook: reminder"), "conversationId" => "self-conv" })
    @mailbox.add("inbox", { **graph_message(id: "in", from: "client@example.com"), "conversationId" => "in-conv" })
    @mailbox.add("sentitems", { **graph_message(id: "out", from: "info@sherpaholidays.com",
      to: "client@example.com"), "conversationId" => "out-conv" })
    @mailbox.add("sentitems", { **graph_message(id: "cc", from: "info@sherpaholidays.com",
      to: "info@sherpaholidays.com", cc: "client@example.com"), "conversationId" => "cc-conv" })

    assert_difference([ "Conversation.count", "Message.count" ], 3) do
      assert_equal 3, Mail::SyncJob.new.perform(fetcher: fetcher)
    end
    assert_not Message.exists?(provider_message_id: "self")
    assert_equal %w[cc in out], Message.where(provider_message_id: %w[self in out cc]).pluck(:provider_message_id).sort
  end

  test "mid-folder failure replays and dedupes on resume" do
    Mail::SyncJob.new.perform(fetcher: fetcher) # prime
    @mailbox.add("inbox", sync_message(id: "one", from: "one@example.com"))
    @mailbox.add("inbox", sync_message(id: "two", from: "two@example.com"))

    original = Mail::Ingester.method(:ingest)
    failing = lambda do |**args|
      raise "interrupted" if args[:parsed].from_addresses == [ "two@example.com" ]

      original.call(**args)
    end
    Mail::Ingester.stub(:ingest, failing) do
      assert_raises(RuntimeError) { Mail::SyncJob.new.perform(fetcher: fetcher) }
    end
    assert_equal 1, Message.count
    # The folder link was not committed, so the next run replays both and
    # dedupes the already-stored one.
    assert_difference("Message.count", 1) do
      assert_equal 1, Mail::SyncJob.new.perform(fetcher: fetcher)
    end
    assert_equal 2, Message.count
    assert MailSyncState.for("inbox").delta_link.present?
  end

  test "run limit leaves the folder link for replay without loss" do
    Mail::SyncJob.new.perform(fetcher: fetcher) # prime
    @mailbox.add("inbox", sync_message(id: "l1", from: "l1@example.com"))
    @mailbox.add("inbox", sync_message(id: "l2", from: "l2@example.com"))

    assert_equal 1, Mail::SyncJob.new.perform(fetcher: fetcher, limit: 1)
    assert_equal 1, Message.count
    assert_equal 1, Mail::SyncJob.new.perform(fetcher: fetcher, limit: 1)
    assert_equal 2, Message.count
  end

  test "revoked grant records the error and stops quietly" do
    Mail::SyncJob.new.perform(fetcher: fetcher) # prime
    @mailbox.refuse_grant!

    assert_no_difference("Message.count") do
      assert_equal false, Mail::SyncJob.new.perform(fetcher: fetcher)
    end
    assert_match(/revoked|Reconnect/i, Setting.current.reload.mailbox_last_error.to_s)
  end

  test "a recovered sync clears the error the captain was shown" do
    Mail::SyncJob.new.perform(fetcher: fetcher) # prime
    Setting.current.update!(mailbox_last_error: "Microsoft Graph is throttling this mailbox. Try again shortly.",
      mailbox_last_error_at: Time.current)
    @mailbox.add("inbox", sync_message(id: "after", from: "after@example.com"))

    assert_equal 1, Mail::SyncJob.new.perform(fetcher: fetcher)
    assert_nil Setting.current.reload.mailbox_last_error
    assert_nil Setting.current.mailbox_last_error_at
  end

  test "the concurrency guard outlives the longest a run can legitimately take" do
    # Solid Queue frees the semaphore when the window lapses, so a window
    # shorter than a working run reads as protection while two runs still
    # drain the same uncommitted position.
    assert_equal 1, Mail::SyncJob.concurrency_limit
    assert Mail::SyncJob.new.concurrency_key.present?
    assert_operator Mail::SyncJob.concurrency_duration, :>, Mail::SyncJob::THROTTLE_ALLOWANCE
    assert_operator Mail::SyncJob.concurrency_duration, :>, 5.minutes
  end

  test "a capped run with a broken folder is reported, not recorded as clean" do
    Mail::SyncJob.new.perform(fetcher: fetcher) # prime
    @mailbox.add("archive", sync_message(id: "bad", from: "operator@example.com"))
    @mailbox.add("inbox", sync_message(id: "good", from: "client@example.com"))
    @mailbox.transport.on_get("/me/messages/bad") do |*|
      { status: 503, json: { "error" => { "code" => "ServiceUnavailable" } } }
    end

    # The cap is reached after the healthy folder yields, which used to let
    # the run finish "successfully" and clear the error it had just recorded.
    assert_raises(Mail::ConnectionError) { Mail::SyncJob.new.perform(fetcher: fetcher, limit: 1) }
    assert_match(/Archive/, Setting.current.reload.mailbox_last_error.to_s)
  end

  test "unconfigured mailbox no-ops" do
    Setting.current.update!(ms_graph_refresh_token: nil)
    assert_equal false, Mail::SyncJob.new.perform(fetcher: fetcher)
  end

  test "an expired access token retries the request without replaying the walk" do
    Mail::SyncJob.new.perform(fetcher: fetcher) # prime
    @mailbox.add("inbox", sync_message(id: "t1", from: "t1@example.com"))
    @mailbox.add("inbox", sync_message(id: "t2", from: "t2@example.com"))
    refusals = 0
    @mailbox.transport.on_get("/me/messages/t2") do |_url, token:, params:, headers:|
      refusals += 1
      if refusals == 1
        { status: 401, json: { "error" => { "code" => "InvalidAuthenticationToken" } } }
      else
        { status: 200, json: @mailbox.find("t2") }
      end
    end

    walks_before = inbox_delta_calls
    assert_difference("Message.count", 2) do
      assert_equal 2, Mail::SyncJob.new.perform(fetcher: fetcher)
    end
    # The refreshed token retried that one request; the folder walk that had
    # already yielded t1 was not started over.
    assert_equal walks_before + 1, inbox_delta_calls
  end

  test "a grant that keeps refusing the token records the error and stops" do
    Mail::SyncJob.new.perform(fetcher: fetcher) # prime
    @mailbox.add("inbox", sync_message(id: "denied", from: "denied@example.com"))
    @mailbox.transport.on_get("/me/messages/denied") do |_url, token:, params:, headers:|
      { status: 401, json: { "error" => { "code" => "InvalidAuthenticationToken" } } }
    end

    assert_no_difference("Message.count") do
      assert_equal false, Mail::SyncJob.new.perform(fetcher: fetcher)
    end
    assert_match(/revoked|Reconnect/i, Setting.current.reload.mailbox_last_error.to_s)
  end

  test "connection errors are recorded and raised for retry" do
    fetcher = Mail::GraphFetcher.new(transport: @mailbox.transport)
    def fetcher.fetch_new(*)
      raise Mail::ConnectionError, "graph down"
    end
    Setting.current.update!(ms_graph_refresh_token: "refresh-0")
    assert_raises(Mail::ConnectionError) { Mail::SyncJob.new.perform(fetcher: fetcher) }
    assert_equal "graph down", Setting.current.reload.mailbox_last_error
  end

  test "variant A: a Graph 400 on one attachment stores the message with a note and syncs messages after it" do
    Mail::SyncJob.new.perform(fetcher: fetcher) # prime
    initial_link = MailSyncState.for("inbox").delta_link

    bad_attachment_msg = graph_message(
      id: "att-400",
      from: "traveler@example.com",
      message_id: "<att400@test>",
      body: "We are ready to book for November.",
      attachments: [ graph_file_attachment(id: "broken-att", name: "broken.pdf", content_type: "application/pdf") ]
    )
    @mailbox.add("inbox", bad_attachment_msg)
    @mailbox.add("inbox", sync_message(id: "after-att-400", from: "later@example.com"))
    @mailbox.transport.on_get("/me/messages/att-400/attachments/broken-att/$value") do |*|
      { status: 400, json: { "error" => { "code" => "ErrorInvalidParameter", "message" => "Cannot read bytes" } } }
    end

    assert_difference("Message.count", 2) do
      assert_equal 2, Mail::SyncJob.new.perform(fetcher: fetcher)
    end

    first = Message.find_by!(provider_message_id: "att-400")
    assert_equal "We are ready to book for November.", first.text_body
    assert_equal 1, first.attachment_notices.size
    assert_includes first.attachment_notices.first, "broken.pdf"
    assert_includes first.attachment_notices.first, "one attachment could not be read, open it in Outlook"
    assert Message.exists?(provider_message_id: "after-att-400")
    assert_not_equal initial_link, MailSyncState.for("inbox").reload.delta_link
    assert_nil Setting.current.reload.mailbox_last_error
  end

  test "variant B: an unexpected error on one message stores later messages and folders, writes mailbox_last_error, and sets the message aside after three attempts so the folder advances" do
    Mail::SyncJob.new.perform(fetcher: fetcher) # prime
    initial_inbox_link = MailSyncState.for("inbox").delta_link

    @mailbox.add("inbox", sync_message(id: "poison-1", from: "poison@example.com"))
    @mailbox.add("inbox", sync_message(id: "healthy-after", from: "healthy@example.com"))
    @mailbox.add("sentitems", { **sync_message(id: "sent-after", from: "info@sherpaholidays.com",
      to: "healthy@example.com"), "conversationId" => "sent-conv" })

    original = Mail::Ingester.method(:ingest)
    failing = lambda do |**args|
      raise ArgumentError, "malformed message payload" if args[:provider][:message_id] == "poison-1"

      original.call(**args)
    end

    Mail::Ingester.stub(:ingest, failing) do
      # Attempt 1: poison-1 fails, but healthy-after (same folder) and sent-after (later folder) both store.
      error = assert_raises(ArgumentError) { Mail::SyncJob.new.perform(fetcher: fetcher) }
      assert_equal "Inbox: malformed message payload", error.message
      assert Message.exists?(provider_message_id: "healthy-after")
      assert Message.exists?(provider_message_id: "sent-after")
      assert_equal "Inbox: malformed message payload", Setting.current.reload.mailbox_last_error
      assert_equal "Inbox: malformed message payload", MailSyncState.for("inbox").last_error
      assert_equal initial_inbox_link, MailSyncState.for("inbox").delta_link

      quarantine = MailMessageQuarantine.find_by!(provider_message_id: "poison-1")
      assert_equal 1, quarantine.attempts
      assert_not quarantine.quarantined?

      # Attempt 2: still below the three-attempt cap; inbox delta_link stays put for one last retry.
      @mailbox.add("inbox", sync_message(id: "healthy-second", from: "second@example.com"))
      assert_raises(ArgumentError) { Mail::SyncJob.new.perform(fetcher: fetcher) }
      assert Message.exists?(provider_message_id: "healthy-second")
      assert_equal 2, quarantine.reload.attempts
      assert_not quarantine.quarantined?
      assert_equal initial_inbox_link, MailSyncState.for("inbox").reload.delta_link

      # Attempt 3: reaches three failed attempts, is set aside, and the
      # folder's delta_link advances with nothing left to read again.
      @mailbox.add("inbox", sync_message(id: "healthy-third", from: "third@example.com"))
      assert_equal 1, Mail::SyncJob.new.perform(fetcher: fetcher)
      assert Message.exists?(provider_message_id: "healthy-third")
      assert_equal 3, quarantine.reload.attempts
      assert quarantine.quarantined?
      advanced_link = MailSyncState.for("inbox").reload.delta_link
      assert_not_equal initial_inbox_link, advanced_link

      # Run 4: live sync leaves poison-1 alone, and new mail in the folder syncs cleanly.
      @mailbox.add("inbox", sync_message(id: "fresh-after-quarantine", from: "fresh@example.com"))
      fetches_before = @mailbox.requests.count { |req| req.url.include?("/me/messages/poison-1") }
      assert_equal 1, Mail::SyncJob.new.perform(fetcher: fetcher)
      fetches_after = @mailbox.requests.count { |req| req.url.include?("/me/messages/poison-1") }
      assert_equal fetches_before, fetches_after
      assert Message.exists?(provider_message_id: "fresh-after-quarantine")
      assert_nil Setting.current.reload.mailbox_last_error
      assert_nil MailSyncState.for("inbox").last_error

      # The clean run cleared the error line, so the waiting row is what
      # the mailbox card still has to count.
      assert_equal [ "poison-1" ], MailMessageQuarantine.quarantined.pluck(:provider_message_id)
    end
  end

  test "one refused message alone in a quiet folder is set aside after three runs and mail behind it is read" do
    Mail::SyncJob.new.perform(fetcher: fetcher) # prime
    initial_link = MailSyncState.for("inbox").delta_link
    @mailbox.add("inbox", sync_message(id: "refused-alone", from: "client@example.com"))
    @mailbox.transport.on_get("/me/messages/refused-alone") do |*|
      { status: 400, json: { "error" => { "code" => "ErrorInvalidRequest", "message" => "Cannot read this item" } } }
    end

    2.times do |n|
      error = assert_raises(Mail::ConnectionError) { Mail::SyncJob.new.perform(fetcher: fetcher) }
      assert_equal "Inbox: Microsoft Graph returned 400 (ErrorInvalidRequest: Cannot read this item)", error.message
      assert_equal error.message, Setting.current.reload.mailbox_last_error
      assert_equal n + 1, MailMessageQuarantine.find_by!(provider_message_id: "refused-alone").attempts
      assert_not MailMessageQuarantine.quarantined?("refused-alone")
      assert_equal initial_link, MailSyncState.for("inbox").reload.delta_link
    end

    assert_equal 0, Mail::SyncJob.new.perform(fetcher: fetcher)
    assert MailMessageQuarantine.quarantined?("refused-alone")
    assert_not_equal initial_link, MailSyncState.for("inbox").reload.delta_link
    assert_nil Setting.current.reload.mailbox_last_error

    opened = @mailbox.requests.count { |request| request.url.include?("/me/messages/refused-alone") }
    assert_equal 3, opened
    @mailbox.add("inbox", sync_message(id: "behind-refused", from: "next@example.com"))
    assert_equal 1, Mail::SyncJob.new.perform(fetcher: fetcher)
    assert Message.exists?(provider_message_id: "behind-refused")
    assert_equal opened, @mailbox.requests.count { |request| request.url.include?("/me/messages/refused-alone") }
  end

  test "a message Graph answers with 5xx every time is set aside after three runs and mail behind it is read" do
    Mail::SyncJob.new.perform(fetcher: fetcher) # prime
    initial_link = MailSyncState.for("inbox").delta_link
    @mailbox.add("inbox", sync_message(id: "always-503", from: "client@example.com"))
    @mailbox.add("inbox", sync_message(id: "behind-503", from: "next@example.com"))
    @mailbox.transport.on_get("/me/messages/always-503") do |*|
      { status: 503, json: { "error" => { "code" => "ServiceUnavailable" } } }
    end

    3.times do |n|
      error = assert_raises(Mail::ConnectionError) { Mail::SyncJob.new.perform(fetcher: fetcher) }
      assert_equal "Inbox: Microsoft Graph returned 503 (ServiceUnavailable)", error.message
      assert_equal n + 1, MailMessageQuarantine.find_by!(provider_message_id: "always-503").attempts
      assert_equal initial_link, MailSyncState.for("inbox").reload.delta_link
    end
    # A 5xx could be all of Graph, so each of those runs stopped reading
    # the folder there instead of pressing on.
    assert_equal 0, @mailbox.requests.count { |request| request.url.include?("/me/messages/behind-503") }
    assert_not Message.exists?(provider_message_id: "behind-503")
    assert MailMessageQuarantine.quarantined?("always-503")

    assert_equal 1, Mail::SyncJob.new.perform(fetcher: fetcher)
    assert Message.exists?(provider_message_id: "behind-503")
    assert_equal 3, @mailbox.requests.count { |request| request.url.include?("/me/messages/always-503") }
    assert_not_equal initial_link, MailSyncState.for("inbox").reload.delta_link
    assert_nil Setting.current.reload.mailbox_last_error
  end

  test "a duplicate of stored mail is neither counted as a failure nor retried" do
    Mail::SyncJob.new.perform(fetcher: fetcher) # prime
    @mailbox.add("inbox", sync_message(id: "original", from: "client@example.com", message_id: "<same@test>"))
    assert_equal 1, Mail::SyncJob.new.perform(fetcher: fetcher)
    initial_link = MailSyncState.for("inbox").delta_link

    # Graph hands a moved or copied message a new id, so it is opened again
    # and the ingester recognizes it by its Message-ID.
    @mailbox.add("inbox", sync_message(id: "refused-beside-copy", from: "other@example.com"))
    @mailbox.add("inbox", sync_message(id: "copy", from: "client@example.com", message_id: "<same@test>"))
    @mailbox.transport.on_get("/me/messages/refused-beside-copy") do |*|
      { status: 400, json: { "error" => { "code" => "ErrorInvalidRequest" } } }
    end

    assert_no_difference("Message.count") do
      2.times do |n|
        assert_raises(Mail::ConnectionError) { Mail::SyncJob.new.perform(fetcher: fetcher) }
        assert_equal({ "refused-beside-copy" => n + 1 }, MailMessageQuarantine.pluck(:provider_message_id, :attempts).to_h)
        assert_equal initial_link, MailSyncState.for("inbox").reload.delta_link
      end

      assert_equal 0, Mail::SyncJob.new.perform(fetcher: fetcher)
    end
    assert_equal({ "refused-beside-copy" => 3 }, MailMessageQuarantine.pluck(:provider_message_id, :attempts).to_h)
    assert_not_equal initial_link, MailSyncState.for("inbox").reload.delta_link
    copy_opened = -> { @mailbox.requests.count { |request| request.url.include?("/me/messages/copy") } }
    assert_equal 3, copy_opened.call

    assert_no_difference("Message.count") do
      assert_equal 0, Mail::SetAsideRetryJob.new.perform(fetcher: fetcher)
    end
    assert_equal 3, copy_opened.call
  end

  test "a three-run outage sets mail aside and the hourly retry reads it all once the outage ends" do
    Mail::SyncJob.new.perform(fetcher: fetcher) # prime
    @mailbox.add("inbox", sync_message(id: "during-outage-1", from: "one@example.com"))
    @mailbox.add("inbox", sync_message(id: "during-outage-2", from: "two@example.com"))
    @mailbox.add("sentitems", { **sync_message(id: "sent-during-outage", from: "info@sherpaholidays.com",
      to: "one@example.com"), "conversationId" => "sent-conv" })

    # The database drops out while mail is being stored.
    Mail::Ingester.stub(:ingest, ->(**) { raise ActiveRecord::ConnectionNotEstablished, "database is unreachable" }) do
      3.times do
        error = assert_raises(ActiveRecord::ConnectionNotEstablished) { Mail::SyncJob.new.perform(fetcher: fetcher) }
        assert_equal "Inbox: database is unreachable", error.message
        assert_equal error.message, Setting.current.reload.mailbox_last_error
      end
    end
    # Each run stopped a folder at its first message instead of pressing
    # on while nothing could be stored, so that is the one set aside.
    assert_equal 0, @mailbox.requests.count { |request| request.url.include?("/me/messages/during-outage-2") }
    assert_equal %w[during-outage-1 sent-during-outage], MailMessageQuarantine.quarantined.pluck(:provider_message_id).sort
    assert_equal 0, Message.count

    # Live sync moves on past what it set aside...
    assert_equal 1, Mail::SyncJob.new.perform(fetcher: fetcher)
    assert Message.exists?(provider_message_id: "during-outage-2")
    assert_nil Setting.current.reload.mailbox_last_error
    assert_equal 2, MailMessageQuarantine.quarantined.count

    # ...and the retry brings the rest in, leaving nothing waiting.
    assert_equal 2, Mail::SetAsideRetryJob.new.perform(fetcher: fetcher)
    assert Message.exists?(provider_message_id: "during-outage-1")
    assert Message.exists?(provider_message_id: "sent-during-outage")
    assert_equal 0, MailMessageQuarantine.count
  end

  test "a Graph outage on one attachment download never stores the message without the file, and the retry brings it in whole" do
    Mail::SyncJob.new.perform(fetcher: fetcher) # prime
    initial_link = MailSyncState.for("inbox").delta_link
    with_attachment = graph_message(
      id: "att-503",
      from: "traveler@example.com",
      message_id: "<att503@test>",
      body: "Our day by day plan is attached.",
      attachments: [ graph_file_attachment(id: "slow-att", name: "itinerary.txt") ]
    )
    @mailbox.add("inbox", with_attachment)
    @mailbox.add("inbox", sync_message(id: "plain-after-503", from: "later@example.com"))
    graph_down = true
    @mailbox.transport.on_get("/me/messages/att-503/attachments/slow-att/$value") do |*|
      if graph_down
        { status: 503, json: { "error" => { "code" => "ServiceUnavailable" } } }
      else
        { status: 200, bytes: "Day 1: Kathmandu" }
      end
    end

    2.times do
      error = assert_raises(Mail::ConnectionError) { Mail::SyncJob.new.perform(fetcher: fetcher) }
      assert_match(/503/, error.message)
      assert_not Message.exists?(provider_message_id: "plain-after-503")
      assert_equal initial_link, MailSyncState.for("inbox").reload.delta_link
    end
    assert_raises(Mail::ConnectionError) { Mail::SyncJob.new.perform(fetcher: fetcher) }
    assert_not Message.exists?(provider_message_id: "att-503")
    assert MailMessageQuarantine.quarantined?("att-503")

    # Still down an hour later: the retry leaves it waiting.
    assert_equal 0, Mail::SetAsideRetryJob.new.perform(fetcher: fetcher)
    assert_not Message.exists?(provider_message_id: "att-503")
    assert MailMessageQuarantine.quarantined?("att-503")

    graph_down = false
    assert_equal 1, Mail::SyncJob.new.perform(fetcher: fetcher)
    assert Message.exists?(provider_message_id: "plain-after-503")
    assert_equal 1, Mail::SetAsideRetryJob.new.perform(fetcher: fetcher)
    stored = Message.find_by!(provider_message_id: "att-503")
    assert_equal "Our day by day plan is attached.", stored.text_body
    assert_equal [ "itinerary.txt" ], stored.files.map { |file| file.filename.to_s }
    assert_equal "Day 1: Kathmandu", stored.files.first.download
    assert_empty Array(stored.attachment_notices)
    assert_equal 0, MailMessageQuarantine.count
    assert_nil Setting.current.reload.mailbox_last_error
  end

  test "a run that stops at its cap while a message is waiting to be read again asks Graph for nothing more and still reports it" do
    Mail::SyncJob.new.perform(fetcher: fetcher) # prime
    @mailbox.add("inbox", sync_message(id: "refused-first", from: "client@example.com"))
    @mailbox.add("inbox", sync_message(id: "stored-at-cap", from: "one@example.com"))
    @mailbox.add("inbox", sync_message(id: "past-cap", from: "two@example.com"))
    @mailbox.add("sentitems", { **sync_message(id: "next-folder", from: "info@sherpaholidays.com",
      to: "one@example.com"), "conversationId" => "sent-conv" })
    @mailbox.transport.on_get("/me/messages/refused-first") do |*|
      { status: 400, json: { "error" => { "code" => "ErrorInvalidRequest" } } }
    end
    sent_requests = -> { @mailbox.requests.count { |request| request.url.include?("sentitems") || request.url.include?("next-folder") } }
    before = sent_requests.call

    error = assert_raises(Mail::ConnectionError) { Mail::SyncJob.new.perform(fetcher: fetcher, limit: 1) }
    assert_match(/\AInbox: Microsoft Graph returned 400/, error.message)
    assert_equal error.message, Setting.current.reload.mailbox_last_error
    assert_equal error.message, MailSyncState.for("inbox").last_error
    assert Message.exists?(provider_message_id: "stored-at-cap")
    assert_not Message.exists?(provider_message_id: "past-cap")
    # The cap ends the run where it stands: the folder after this one is
    # not read and nothing in it is opened.
    assert_equal before, sent_requests.call
    assert_not Message.exists?(provider_message_id: "next-folder")
    assert_equal 1, MailMessageQuarantine.find_by!(provider_message_id: "refused-first").attempts
  end
end
