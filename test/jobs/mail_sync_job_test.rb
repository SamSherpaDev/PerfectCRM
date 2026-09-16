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
end
