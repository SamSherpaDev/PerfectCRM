require "test_helper"
require_relative "../support/graph_fake"

class MailImportJobTest < ActiveSupport::TestCase
  include GraphMessageBuilder

  setup do
    @mailbox = FakeMailbox.new
    Setting.current.update!(ms_graph_refresh_token: "refresh-0")
  end

  def fetcher
    Mail::GraphFetcher.new(transport: @mailbox.transport)
  end

  def import_raw(id:, from:, to: "info@sherpaholidays.com", folder: "inbox", message_id: nil, received: nil)
    @mailbox.add(folder, graph_message(id: id, from: from, to: to,
      message_id: message_id || "<#{id}@test>",
      received: received || "2026-09-#{10 + id.to_s.length}T10:00:00Z"))
  end

  test "import is resumable and respects the info@ rule" do
    import = MailImport.create!(scope: "all", status: "draft", total_messages: 3)
    import_raw(id: "i1", from: "a@example.com")
    import_raw(id: "i2", from: "friend@gmail.com", to: "captain@gmail.com")
    import_raw(id: "i3", from: "b@example.com")

    Mail::ImportJob.new.perform(import.id, fetcher: fetcher)
    import.reload
    assert_equal "done", import.status
    assert_equal 0, import.linked_messages
    assert_equal 2, import.skipped_messages
    assert_equal 2, import.processed_messages
  end

  test "choices link already ingested outbound conversations" do
    raw = "From: info@sherpaholidays.com\r\nTo: outbound@example.com\r\nMessage-ID: <outbound-import@test>\r\n\r\nHi"
    result = Mail::Ingester.ingest(parsed: Mail::Ingester.parse_raw(raw), provider: {})
    import = MailImport.create!(scope: "all", status: "preview",
      preview_json: { "choices" => { "outbound@example.com" => "client" } })
    @mailbox.add("sentitems", graph_message(id: "outbound-1", from: "info@sherpaholidays.com",
      to: "outbound@example.com", message_id: "<outbound-import@test>"))
    assert_difference("Client.count", 1) do
      assert_no_difference("Message.count") { Mail::ImportJob.new.perform(import.id, fetcher: fetcher) }
    end
    assert result[:conversation].reload.linked?
    assert_equal 1, import.reload.linked_messages
    assert_equal 1, import.created_clients
  end

  test "resume uses the cursor when earlier mail disappears" do
    import_raw(id: "resume1", from: "sender1@example.com", received: "2026-09-11T10:00:00Z")
    import_raw(id: "resume2", from: "sender2@example.com", received: "2026-09-12T10:00:00Z")
    import_raw(id: "resume3", from: "sender3@example.com", received: "2026-09-13T10:00:00Z")
    import = MailImport.create!(scope: "all", status: "preview", preview_json: {})

    original = Mail::Ingester.method(:ingest)
    Mail::Ingester.stub(:ingest, ->(**args) { args[:parsed].message_id == "resume2@test" ? raise("interrupted") : original.call(**args) }) do
      assert_raises(RuntimeError) { Mail::ImportJob.new.perform(import.id, fetcher: fetcher) }
    end
    assert_equal "inbox|2026-09-11T10:00:00.000000Z", import.reload.preview_json["history_cursor"]
    @mailbox.instance_variable_get(:@messages)["inbox"].reject! { |message| message["id"] == "resume1" }
    assert_difference("Message.count", 2) { Mail::ImportJob.new.perform(import.id, fetcher: fetcher) }
    assert_equal 3, import.reload.processed_messages
  end

  test "every approved counterparty is created without replacing the thread owner" do
    owner = Client.create!(name: "Owner", email: "owner@example.com")
    [ false, true ].each do |linked|
      suffix = linked ? "linked" : "new"
      recipients = [ "first-#{suffix}@example.com", "second-#{suffix}@example.com", "operator-#{suffix}@example.com" ]
      raw = "From: info@sherpaholidays.com\r\nTo: #{recipients.join(", ")}\r\nMessage-ID: <#{suffix}@test>\r\n\r\nHello"
      result = Mail::Ingester.ingest(parsed: Mail::Ingester.parse_raw(raw),
        provider: { message_id: "pre-#{suffix}", thread_id: "conv-#{suffix}", labels: [] })
      result[:conversation].update!(linkable: owner) if linked
      choices = { recipients[0] => "client", recipients[1] => "client", recipients[2] => "organization" }
      import = MailImport.create!(scope: "all", status: "preview", preview_json: { "choices" => choices })
      # The same mail re-imported from Graph dedupes by Message-ID, while the
      # approved choices still apply to every counterparty.
      @mailbox.add("sentitems", graph_message(id: "multi-#{suffix}", from: "info@sherpaholidays.com",
        to: recipients, message_id: "<#{suffix}@test>"))
      assert_difference("Client.count", 2) do
        assert_difference("Organization.count", 1) do
          Mail::ImportJob.new.perform(import.id, fetcher: fetcher)
        end
      end
      assert_equal 2, import.reload.created_clients
      assert_equal 1, import.created_organizations
      recipients.each { |email| assert EmailIdentity.find_for(email).linkable }
      expected = linked ? owner : Client.find_by!(email: recipients.first)
      assert_equal expected, result[:conversation].reload.linkable
    end
  end

  test "kept-only progress matches the preview count" do
    3.times { |n| import_raw(id: "personal#{n}", from: "friend@example.com", to: "captain@gmail.com") }
    import_raw(id: "business", from: "business@example.com")
    import = MailImport.create!(scope: "all", status: "preview", total_messages: 1, preview_json: {})

    original = Mail::Ingester.method(:ingest)
    Mail::Ingester.stub(:ingest, ->(**args) { args[:parsed].message_id == "business@test" ? raise("interrupted") : original.call(**args) }) do
      assert_raises(RuntimeError) { Mail::ImportJob.new.perform(import.id, fetcher: fetcher) }
    end
    # Personal mail never yields, so the cursor stays put and progress is zero.
    assert_nil import.reload.preview_json["history_cursor"]
    assert_equal 0, import.processed_messages
    assert_equal 0, import.progress_pct
    Mail::ImportJob.new.perform(import.id, fetcher: fetcher)
    assert_equal 1, import.reload.processed_messages
    assert_equal 100, import.progress_pct
  end
end
