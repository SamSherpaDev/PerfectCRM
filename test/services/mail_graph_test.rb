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
    assert_equal %w[Mail.Read User.Read offline_access], query["scope"].split.sort
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

  test "connect refuses another Microsoft account and stores nothing" do
    Setting.current.update!(ms_graph_refresh_token: nil)
    @mailbox.signed_in_as("sam@personal.example")

    error = assert_raises(Mail::WrongMailboxError) do
      Mail::GraphAuth.connect!(code: "auth-code",
        redirect_uri: "https://crm.example/auth/microsoft/callback", transport: @transport)
    end
    assert_match(/sam@personal\.example/, error.message)
    assert_match(/info@sherpaholidays\.com/, error.message)
    settings = Setting.current.reload
    assert_nil settings.ms_graph_refresh_token
    assert_not settings.mailbox_connected?
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

  test "live sync reads mail filed outside the Inbox" do
    fetcher.fetch_new.to_a # prime
    @mailbox.add("archive", graph_message(id: "filed-live", from: "operator@example.com",
      message_id: "<filedlive@test>"))
    @mailbox.add("clients", graph_message(id: "nested-live", from: "traveler@example.com",
      message_id: "<nestedlive@test>"))
    @mailbox.add("deleteditems", graph_message(id: "binned-live", from: "binned@example.com",
      message_id: "<binnedlive@test>"))

    items = fetcher.fetch_new.to_a
    assert_equal %w[filed-live nested-live], items.map { |item| item.provider[:message_id] }.sort
  end

  test "a folder created after the first connect is primed, not backfilled" do
    @mailbox.add("inbox", graph_message(id: "before", from: "before@example.com", message_id: "<before@test>"))
    fetcher.fetch_new.to_a # prime every folder that exists now

    @mailbox.add_folder("operators", display_name: "Operators")
    @mailbox.add("operators", graph_message(id: "old-filed", from: "operator@example.com",
      message_id: "<oldfiled@test>"))
    assert_empty fetcher.fetch_new.to_a
    assert MailSyncState.for("operators").delta_link.present?

    @mailbox.add("operators", graph_message(id: "new-filed", from: "operator@example.com",
      message_id: "<newfiled@test>"))
    assert_equal [ "new-filed" ], fetcher.fetch_new.to_a.map { |item| item.provider[:message_id] }
  end

  test "first connect primes every folder and stores nothing" do
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

  test "already stored mail is skipped before the message is refetched" do
    fetcher.fetch_new.to_a # prime
    link_before = MailSyncState.for("inbox").delta_link
    @mailbox.add("inbox", graph_message(id: "reread", from: "client@example.com", message_id: "<reread@test>",
      attachments: [ graph_file_attachment(id: "r1", name: "itinerary.txt") ]),
      file_bytes: { "r1" => "itinerary bytes" })
    first = fetcher.fetch_new.map { |item| Mail::Ingester.ingest(parsed: item.parsed, provider: item.provider)[:status] }
    assert_equal [ :stored ], first
    assert_equal 1, Message.where(message_id: "reread@test").count

    # The server replays the same change (e.g. a read-state toggle): syncing
    # from the previous link returns it again and nothing is downloaded.
    MailSyncState.for("inbox").update!(delta_link: link_before)
    fetches_before = @mailbox.message_fetches
    bytes_before = @mailbox.byte_fetches
    assert_empty fetcher.fetch_new.to_a
    assert_equal fetches_before, @mailbox.message_fetches
    assert_equal bytes_before, @mailbox.byte_fetches
    assert_equal 1, Message.where(message_id: "reread@test").count
  end

  test "an HTML message keeps its whole body instead of the Graph preview" do
    fetcher.fetch_new.to_a # prime
    full = "<p>#{"The full itinerary. " * 40}</p>"
    @mailbox.add("inbox", graph_message(id: "rich", from: "client@example.com", message_id: "<rich@test>",
      body: full, body_type: "html", preview: "The full itinerary. The full"))

    items = fetcher.fetch_new.to_a
    assert_nil items.first.parsed.text_body
    assert_equal full, items.first.parsed.html_body
    stored = Mail::Ingester.ingest(parsed: items.first.parsed, provider: items.first.provider)[:message]
    assert_nil stored.text_body
    assert_includes stored.html_body, "The full itinerary."
    assert_operator stored.html_body.length, :>, 600
  end

  test "attachment bytes are only fetched when a message is stored" do
    fetcher.fetch_new.to_a # prime
    @mailbox.add("inbox", graph_message(id: "lazy-1", from: "client@example.com",
      message_id: "<lazy@test>", attachments: [ graph_file_attachment(id: "l1", name: "itinerary.txt") ]),
      file_bytes: { "l1" => "itinerary bytes" })

    items = fetcher.fetch_new.to_a
    assert_equal 1, items.length
    assert_equal 0, @mailbox.byte_fetches
    result = Mail::Ingester.ingest(parsed: items.first.parsed, provider: items.first.provider)
    assert_equal 1, @mailbox.byte_fetches
    assert_equal "itinerary bytes", result[:message].files.first.download
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

  test "hidden-Bcc delivery is kept only through a real recipient header" do
    fetcher.fetch_new.to_a # prime
    @mailbox.add("inbox", graph_message(id: "bcc-1", from: "operator@example.com", to: "manifest@example.com",
      message_id: "<bcc@test>",
      headers: [ { "name" => "Delivered-To", "value" => "info@sherpaholidays.com" } ]))

    items = fetcher.fetch_new.to_a
    assert_equal [ "bcc-1" ], items.map { |item| item.provider[:message_id] }
    assert_equal :stored, Mail::Ingester.ingest(parsed: items.first.parsed, provider: items.first.provider)[:status]
  end

  test "personal mail naming the mailbox outside a recipient header is not kept" do
    fetcher.fetch_new.to_a # prime
    @mailbox.add("inbox", graph_message(id: "reply-to-1", from: "friend@example.com",
      to: "captain@gmail.com", message_id: "<replyto@test>",
      headers: [ { "name" => "Reply-To", "value" => "info@sherpaholidays.com" },
        { "name" => "List-Post", "value" => "<mailto:info@sherpaholidays.com>" } ]))

    assert_no_difference([ "Conversation.count", "Message.count" ]) do
      assert_empty fetcher.fetch_new.to_a
    end
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

    # Resuming replays the cursor's second and everything after it.
    second = items[1]
    rest = fetcher.fetch_history(since: Time.utc(2026, 9, 1), cursor: second.cursor).to_a
    assert_equal %w[h-2 h-3], rest.map { |item| item.provider[:message_id] }

    # Vanished mail cannot shift the resume point.
    @mailbox.instance_variable_get(:@messages)["inbox"].reject! { |message| message["id"] == "h-1" }
    rest = fetcher.fetch_history(since: Time.utc(2026, 9, 1), cursor: items[0].cursor).to_a
    assert_equal %w[h-2 h-3], rest.map { |item| item.provider[:message_id] }
  end

  test "resuming inside one folder keeps older mail in the folders after it" do
    @mailbox.add("inbox", graph_message(id: "r-in", from: "client@example.com",
      message_id: "<rin@test>", received: "2026-09-14T10:00:00Z"))
    @mailbox.add("sentitems", graph_message(id: "r-out", from: "info@sherpaholidays.com",
      to: "client@example.com", message_id: "<rout@test>", received: "2026-09-02T10:00:00Z"))

    items = fetcher.fetch_history(since: Time.utc(2026, 9, 1)).to_a
    assert_equal %w[r-in r-out], items.map { |item| item.provider[:message_id] }

    # Resuming after the inbox message must not carry that folder's floor
    # into Sent Items, where older replies still need importing.
    rest = fetcher.fetch_history(since: Time.utc(2026, 9, 1), cursor: items.first.cursor).to_a
    assert_equal %w[r-in r-out], rest.map { |item| item.provider[:message_id] }
  end

  test "resuming replays the cursor second so same-second mail is never dropped" do
    %w[AAAA ZZZZ].each do |id|
      @mailbox.add("inbox", graph_message(id: id, from: "#{id.downcase}@example.com",
        message_id: "<#{id}@test>", received: "2026-09-12T10:00:00Z"))
    end

    items = fetcher.fetch_history.to_a
    assert_equal 2, items.length
    # Graph orders messages sharing a receivedDateTime however it likes, so
    # resuming from the first one still has to return both.
    rest = fetcher.fetch_history(cursor: items.first.cursor).to_a
    assert_equal items.map { |item| item.provider[:message_id] }.sort,
      rest.map { |item| item.provider[:message_id] }.sort
  end

  test "a throttled request waits for Retry-After and then succeeds" do
    fetcher.fetch_new.to_a # prime
    @mailbox.add("inbox", graph_message(id: "slow", from: "client@example.com", message_id: "<slow@test>"))
    throttles = 0
    @transport.on_get("/me/messages/slow") do |_url, token:, params:, headers:|
      throttles += 1
      if throttles <= 2
        { status: 429, json: { "error" => { "code" => "ApplicationThrottled" } }, retry_after: "0" }
      else
        { status: 200, json: @mailbox.find("slow") }
      end
    end

    items = fetcher.fetch_new.to_a
    assert_equal [ "slow" ], items.map { |item| item.provider[:message_id] }
    assert_equal 3, throttles
  end

  test "a throttle that will not let up gives up as a connection error" do
    fetcher.fetch_new.to_a # prime
    @mailbox.add("inbox", graph_message(id: "blocked", from: "client@example.com", message_id: "<blocked@test>"))
    throttles = 0
    @transport.on_get("/me/messages/blocked") do |_url, token:, params:, headers:|
      throttles += 1
      { status: 429, json: { "error" => { "code" => "ApplicationThrottled" } }, retry_after: "0" }
    end

    assert_raises(Mail::ConnectionError) { fetcher.fetch_new.to_a }
    assert_equal Mail::GraphClient::THROTTLE_WAITS + 1, throttles
  end

  test "an HTTP-date Retry-After is honoured instead of collapsing to no wait" do
    client = Mail::GraphClient.new(transport: @transport) { "token" }
    assert_equal Mail::GraphClient::MAX_WAIT_SECONDS,
      client.send(:wait_seconds, 10.minutes.from_now.httpdate)
    assert_equal 2, client.send(:wait_seconds, 2.seconds.from_now.httpdate)
    assert_equal Mail::GraphClient::DEFAULT_WAIT_SECONDS, client.send(:wait_seconds, "soon please")
    assert_equal Mail::GraphClient::DEFAULT_WAIT_SECONDS, client.send(:wait_seconds, nil)
  end

  test "history walks archived and nested folders but not the ones without correspondence" do
    @mailbox.add("archive", graph_message(id: "filed", from: "operator@example.com", message_id: "<filed@test>"))
    @mailbox.add("clients", graph_message(id: "nested", from: "traveler@example.com", message_id: "<nested@test>"))
    @mailbox.add("inbox", graph_message(id: "current", from: "client@example.com", message_id: "<current@test>"))
    @mailbox.add("sentitems", graph_message(id: "replied", from: "info@sherpaholidays.com",
      to: "client@example.com", message_id: "<replied@test>"))
    %w[deleteditems junkemail drafts outbox conversationhistory].each do |folder|
      @mailbox.add(folder, graph_message(id: "#{folder}-1", from: "#{folder}@example.com",
        message_id: "<#{folder}@test>"))
    end

    items = fetcher.fetch_history.to_a
    assert_equal %w[current filed nested replied], items.map { |item| item.provider[:message_id] }.sort
  end

  test "a forward enclosing another forward is held whole, passport and all" do
    fetcher.fetch_new.to_a # prime
    innermost = {
      "subject" => "Documents", "internetMessageId" => "<innermost@test>",
      "from" => graph_address("traveler@example.com"),
      "toRecipients" => [ graph_address("agent@example.com") ],
      "body" => { "contentType" => "text", "content" => "Papers attached" },
      "attachments" => [
        { "@odata.type" => "#microsoft.graph.fileAttachment", "id" => "deep-1",
          "name" => "passport.pdf", "contentType" => "application/pdf", "size" => 21,
          "contentBytes" => Base64.strict_encode64("deep passport bytes") }
      ]
    }
    middle = {
      "subject" => "Fwd: Documents", "internetMessageId" => "<middle@test>",
      "from" => graph_address("agent@example.com"),
      "toRecipients" => [ graph_address("forwarder@example.com") ],
      "body" => { "contentType" => "text", "content" => "Passing this along" },
      "attachments" => [
        { "@odata.type" => "#microsoft.graph.itemAttachment", "id" => "inner-w",
          "name" => "documents", "contentType" => "message/rfc822", "size" => 900,
          "item" => innermost }
      ]
    }
    message = graph_message(id: "fwd-deep", from: "forwarder@example.com", message_id: "<fwddeep@test>",
      attachments: [ graph_item_attachment(id: "outer-w", name: "forwarded") ])
    @mailbox.add("inbox", message, nested: { "outer-w" => middle })

    items = fetcher.fetch_new.to_a
    result = Mail::Ingester.ingest(parsed: items.first.parsed, provider: items.first.provider)
    stored = result[:message]
    # Graph hands back one level of a forwarded message, so what the inner
    # forward encloses cannot be screened; the whole forward is held rather
    # than stored, and the passport never becomes a download.
    assert_empty stored.files
    assert_equal [ "forwarded.eml" ], stored.held_attachments.map { |entry| entry["filename"] }
    assert_not_includes DocumentHolding.find_by!(message: stored).file.download, "deep passport bytes"
  end

  test "a forward that says it has attachments Graph did not return is held whole" do
    fetcher.fetch_new.to_a # prime
    withheld = {
      "subject" => "Fwd: paperwork", "internetMessageId" => "<withheld@test>",
      "from" => graph_address("agent@example.com"),
      "toRecipients" => [ graph_address("info@sherpaholidays.com") ],
      "body" => { "contentType" => "text", "content" => "Documents attached" },
      "hasAttachments" => true
    }
    message = graph_message(id: "fwd-withheld", from: "agent@example.com", message_id: "<fwdwithheld@test>",
      attachments: [ graph_item_attachment(id: "outer-h", name: "forwarded") ])
    @mailbox.add("inbox", message, nested: { "outer-h" => withheld })

    items = fetcher.fetch_new.to_a
    stored = Mail::Ingester.ingest(parsed: items.first.parsed, provider: items.first.provider)[:message]
    assert_empty stored.files
    assert_equal [ "forwarded.eml" ], stored.held_attachments.map { |entry| entry["filename"] }
  end

  test "a forward whose enclosure cannot be read is held instead of stored" do
    fetcher.fetch_new.to_a # prime
    unreadable = {
      "subject" => "Fwd: trip", "internetMessageId" => "<unreadable@test>",
      "from" => graph_address("agent@example.com"),
      "toRecipients" => [ graph_address("info@sherpaholidays.com") ],
      "body" => { "contentType" => "text", "content" => "See below" },
      "attachments" => [
        # Graph handed back no item for this enclosed forward, so nothing
        # inside it could be screened.
        { "@odata.type" => "#microsoft.graph.itemAttachment", "id" => "opaque",
          "name" => "enclosed", "contentType" => "message/rfc822", "size" => 500 }
      ]
    }
    message = graph_message(id: "fwd-opaque", from: "agent@example.com", message_id: "<fwdopaque@test>",
      attachments: [ graph_item_attachment(id: "outer-o", name: "forwarded") ])
    @mailbox.add("inbox", message, nested: { "outer-o" => unreadable })

    items = fetcher.fetch_new.to_a
    stored = Mail::Ingester.ingest(parsed: items.first.parsed, provider: items.first.provider)[:message]
    assert_empty stored.files
    assert_equal [ "forwarded.eml" ], stored.held_attachments.map { |entry| entry["filename"] }
  end

  test "unconfigured fetcher refuses to run" do
    Setting.current.update!(ms_graph_refresh_token: nil)
    assert_not fetcher.configured?
    assert_raises(Mail::NotConfiguredError) { fetcher.fetch_new.to_a }
    assert_raises(Mail::NotConfiguredError) { fetcher.test_connection }
  end
end
