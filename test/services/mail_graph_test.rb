require "test_helper"
require_relative "../support/graph_fake"

class MailGraphTest < ActiveSupport::TestCase
  include GraphMessageBuilder

  setup do
    @mailbox = FakeMailbox.new
    @transport = @mailbox.transport
    Setting.current.update!(ms_graph_refresh_token: "refresh-0",
      mailbox_last_error: nil, mailbox_last_error_at: nil)
  end

  def fetcher
    Mail::GraphFetcher.new(transport: @transport)
  end

  test "authorization url carries the delegated scopes and state" do
    url = Mail::GraphAuth.authorization_url(redirect_uri: "https://crm.example/auth/microsoft/callback", state: "s3cr3t")
    assert_match %r{\Ahttps://login\.microsoftonline\.com/test-tenant/oauth2/v2\.0/authorize\?}, url
    query = URI.decode_www_form(URI.parse(url).query).to_h
    assert_equal "test-client-id", query["client_id"]
    assert_equal "code", query["response_type"]
    assert_equal "s3cr3t", query["state"]
    assert_includes query["scope"].split, "offline_access"
    assert_includes query["scope"].split, "Mail.Read"
    assert_includes query["scope"].split, "Mail.ReadBasic"
    assert_includes query["scope"].split, "User.Read"
  end

  test "connect exchanges the code and stores the refresh token encrypted" do
    Mail::GraphAuth.connect!(code: "auth-code",
      redirect_uri: "https://crm.example/auth/microsoft/callback", transport: @transport)
    settings = Setting.current.reload
    assert_equal "refresh-2", settings.ms_graph_refresh_token
    raw = Setting.connection.select_value("SELECT ms_graph_refresh_token FROM settings WHERE id = #{settings.id}")
    assert_not_includes raw.to_s, "refresh-2"
    assert settings.mailbox_connected?
  end

  test "access token refresh persists a rotated refresh token" do
    token = Mail::GraphAuth.access_token!(transport: @transport)
    assert_equal "access-1", token
    assert_equal "refresh-2", Setting.current.reload.ms_graph_refresh_token
    token = Mail::GraphAuth.access_token!(transport: @transport)
    assert_equal "access-2", token
    assert_equal "refresh-3", Setting.current.reload.ms_graph_refresh_token
  end

  test "revoked grant raises GrantRevokedError on refresh" do
    @mailbox.refuse_grant!
    assert_raises(Mail::GrantRevokedError) { Mail::GraphAuth.access_token!(transport: @transport) }
  end

  test "test connection checks /me and surfaces revocation" do
    assert fetcher.test_connection
    @mailbox.refuse_grant!
    assert_raises(Mail::GrantRevokedError) { fetcher.test_connection }
  end

  test "first connect primes both folders and stores nothing" do
    @mailbox.add("inbox", graph_message(id: "old-1", from: "old@example.com", message_id: "<old1@test>"))
    @mailbox.add("inbox", graph_message(id: "old-2", from: "old@example.com", message_id: "<old2@test>"))
    @mailbox.add("sentitems", graph_message(id: "old-sent", from: "info@sherpaholidays.com",
      to: "someone@example.com", message_id: "<oldsent@test>"))

    assert_no_difference([ "Conversation.count", "Message.count" ]) do
      assert_equal 0, fetcher.fetch_new.to_a.length
    end
    assert MailSyncState.for("inbox").delta_link.present?
    assert MailSyncState.for("sentitems").delta_link.present?
  end

  test "incremental sync stores inbox and sent mail and persists delta links" do
    fetcher.fetch_new.to_a # prime
    first_link = MailSyncState.for("inbox").delta_link
    @mailbox.add("inbox", graph_message(id: "g-in", from: "client@example.com",
      message_id: "<gin@test>", conversation: "thread-g", categories: [ "Travel" ]))
    @mailbox.add("sentitems", graph_message(id: "g-out", from: "info@sherpaholidays.com",
      to: "client@example.com", message_id: "<gout@test>", conversation: "thread-g"))

    items = fetcher.fetch_new.to_a
    assert_equal 2, items.length
    assert_equal %w[inbox sentitems], items.map(&:folder)
    stored = nil
    assert_difference("Message.count", 2) do
      stored = items.count { |item| Mail::Ingester.ingest(parsed: item.parsed, provider: item.provider)[:status] == :stored }
    end
    assert_equal 2, stored
    assert_not_equal first_link, MailSyncState.for("inbox").delta_link

    inbound = Message.find_by!(provider_message_id: "g-in")
    assert_equal "gin@test", inbound.message_id
    assert_equal [ "Travel" ], inbound.label_list
    assert_equal inbound.conversation_id, Message.find_by!(provider_message_id: "g-out").conversation_id
    assert_equal "thread-g", inbound.conversation.provider_thread_id
  end

  test "delta pagination is drained and removed entries are skipped" do
    fetcher.fetch_new.to_a # prime
    @mailbox.add("inbox", graph_message(id: "p-1", from: "one@example.com", message_id: "<p1@test>"))
    @mailbox.add("inbox", graph_message(id: "p-2", from: "two@example.com", message_id: "<p2@test>"))
    @mailbox.add("inbox", { "@removed" => { "reason" => "deleted" }, "id" => "gone-1" })

    items = fetcher.fetch_new.to_a
    assert_equal %w[p-1 p-2], items.map { |item| item.provider[:message_id] }
  end

  test "read-state-only changes resolve to duplicates, never stored twice" do
    fetcher.fetch_new.to_a # prime
    link_before = MailSyncState.for("inbox").delta_link
    @mailbox.add("inbox", graph_message(id: "reread", from: "client@example.com", message_id: "<reread@test>"))
    first = fetcher.fetch_new.map { |item| Mail::Ingester.ingest(parsed: item.parsed, provider: item.provider)[:status] }
    assert_equal [ :stored ], first
    assert_equal 1, Message.where(message_id: "reread@test").count

    # The server replays the same change (e.g. a read-state toggle): syncing
    # from the previous link returns it again, and it dedupes.
    MailSyncState.for("inbox").update!(delta_link: link_before)
    second = fetcher.fetch_new.map { |item| Mail::Ingester.ingest(parsed: item.parsed, provider: item.provider)[:status] }
    assert_equal [ :duplicate ], second
    assert_equal 1, Message.where(message_id: "reread@test").count
  end

  test "personal mail is skipped before any attachment bytes are fetched" do
    fetcher.fetch_new.to_a # prime
    personal = graph_message(id: "private-1", from: "friend@gmail.com", to: "captain@gmail.com",
      message_id: "<private@test>",
      attachments: [ graph_file_attachment(id: "a1", name: "secret.txt") ])
    @mailbox.add("inbox", personal, file_bytes: { "a1" => "private bytes" })

    assert_no_difference([ "Conversation.count", "Message.count" ]) do
      assert_empty fetcher.fetch_new.to_a
    end
    assert_equal 0, @mailbox.byte_fetches
  end

  test "hidden-Bcc delivery to the mailbox is kept via the header trace" do
    fetcher.fetch_new.to_a # prime
    bcc = graph_message(id: "bcc-1", from: "operator@example.com", to: "manifest@example.com",
      message_id: "<bcc@test>",
      headers: [ { "name" => "Received",
        "value" => "from mail.example.com by outlook.com for <info@sherpaholidays.com>" } ])
    @mailbox.add("inbox", bcc)

    items = fetcher.fetch_new.to_a
    assert_equal 1, items.length
    assert_equal :stored, Mail::Ingester.ingest(parsed: items.first.parsed, provider: items.first.provider)[:status]
  end

  test "sensitive attachments are held with bytes in the holding area" do
    fetcher.fetch_new.to_a # prime
    message = graph_message(id: "docs-1", from: "traveler@example.com", message_id: "<docs@test>",
      attachments: [
        graph_file_attachment(id: "f1", name: "itinerary.txt"),
        graph_file_attachment(id: "f2", name: "passport.pdf", content_type: "application/pdf")
      ])
    @mailbox.add("inbox", message, file_bytes: { "f1" => "ordinary bytes", "f2" => "passport bytes" })

    items = fetcher.fetch_new.to_a
    assert_equal 1, items.length
    result = Mail::Ingester.ingest(parsed: items.first.parsed, provider: items.first.provider)
    assert_equal :stored, result[:status]
    stored = result[:message]
    assert_equal "ordinary bytes", stored.files.first.download
    assert_equal [ "passport.pdf" ], stored.held_attachments.map { |entry| entry["filename"] }
    assert_equal "passport bytes", DocumentHolding.find_by!(message: stored).file.download
  end

  test "forwarded message carrying passport.pdf holds it without storing files" do
    fetcher.fetch_new.to_a # prime
    nested_item = {
      "subject" => "Fwd: documents", "internetMessageId" => "<nested@test>",
      "from" => graph_address("traveler@example.com"),
      "toRecipients" => [ graph_address("info@sherpaholidays.com") ],
      "body" => { "contentType" => "text", "content" => "See attached" },
      "attachments" => [
        { "@odata.type" => "#microsoft.graph.fileAttachment", "id" => "n1",
          "name" => "passport.pdf", "contentType" => "application/pdf", "size" => 14,
          "contentBytes" => Base64.strict_encode64("nested passport bytes") }
      ]
    }
    message = graph_message(id: "fwd-1", from: "forwarder@example.com", message_id: "<fwd@test>",
      attachments: [ graph_item_attachment(id: "w1", name: "forwarded") ])
    @mailbox.add("inbox", message, nested: { "w1" => nested_item })

    items = fetcher.fetch_new.to_a
    assert_equal 1, items.length
    result = Mail::Ingester.ingest(parsed: items.first.parsed, provider: items.first.provider)
    assert_equal :stored, result[:status]
    stored = result[:message]
    assert_empty stored.files
    assert_equal [ "passport.pdf" ], stored.held_attachments.map { |entry| entry["filename"] }
    assert_equal "nested passport bytes", DocumentHolding.find_by!(message: stored).file.download
  end

  test "expired delta link re-primes without ingesting the mailbox" do
    fetcher.fetch_new.to_a # prime
    @mailbox.add("inbox", graph_message(id: "veteran", from: "old@example.com", message_id: "<veteran@test>"))
    @mailbox.expire_delta!("inbox")

    assert_no_difference([ "Conversation.count", "Message.count" ]) do
      fetcher.fetch_new.to_a
    end
    # The re-prime consumed history: a later arrival still syncs.
    @mailbox.add("inbox", graph_message(id: "fresh", from: "new@example.com", message_id: "<fresh@test>"))
    items = fetcher.fetch_new.to_a
    assert_equal [ "fresh" ], items.map { |item| item.provider[:message_id] }
  end

  test "history walk pages both folders with a received-date filter" do
    @mailbox.add("inbox", graph_message(id: "h-old", from: "old@example.com",
      message_id: "<hold@test>", received: "2025-01-01T10:00:00Z"))
    @mailbox.add("inbox", graph_message(id: "h-1", from: "a@example.com",
      message_id: "<h1@test>", received: "2026-09-10T10:00:00Z"))
    @mailbox.add("inbox", graph_message(id: "h-2", from: "b@example.com",
      message_id: "<h2@test>", received: "2026-09-12T10:00:00Z"))
    @mailbox.add("sentitems", graph_message(id: "h-3", from: "info@sherpaholidays.com",
      to: "c@example.com", message_id: "<h3@test>", received: "2026-09-13T10:00:00Z"))

    items = fetcher.fetch_history(since: Time.utc(2026, 9, 1)).to_a
    assert_equal %w[h-1 h-2 h-3], items.map { |item| item.provider[:message_id] }
    assert items.all? { |item| item.cursor.present? }

    # Resume cursor skips everything at or before it, across folders.
    second = items[1]
    rest = fetcher.fetch_history(since: Time.utc(2026, 9, 1), cursor: second.cursor).to_a
    assert_equal %w[h-3], rest.map { |item| item.provider[:message_id] }

    # Vanished mail cannot shift the resume point.
    @mailbox.instance_variable_get(:@messages)["inbox"].reject! { |message| message["id"] == "h-1" }
    rest = fetcher.fetch_history(since: Time.utc(2026, 9, 1), cursor: items[0].cursor).to_a
    assert_equal %w[h-2 h-3], rest.map { |item| item.provider[:message_id] }
  end

  test "unconfigured fetcher refuses to run" do
    Setting.current.update!(ms_graph_refresh_token: nil)
    assert_not fetcher.configured?
    assert_raises(Mail::NotConfiguredError) { fetcher.fetch_new.to_a }
    assert_raises(Mail::NotConfiguredError) { fetcher.test_connection }
  end
end
