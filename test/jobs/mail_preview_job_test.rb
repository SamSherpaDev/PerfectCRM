require "test_helper"
require_relative "../support/graph_fake"

class MailPreviewJobTest < ActiveSupport::TestCase
  include GraphMessageBuilder

  setup do
    @mailbox = FakeMailbox.new
    Setting.current.update!(ms_graph_refresh_token: "refresh-0")
  end

  def fetcher
    Mail::GraphFetcher.new(transport: @mailbox.transport)
  end

  test "preview counts kept mail across pages and resumes after failure" do
    3.times do |n|
      @mailbox.add("inbox", graph_message(id: "bulk-#{n}", from: "friend@gmail.com",
        to: "captain@gmail.com", message_id: "<bulk#{n}@test>", received: "2026-09-0#{n + 1}T10:00:00Z"))
    end
    @mailbox.add("inbox", graph_message(id: "biz", from: "client@example.com",
      message_id: "<business@test>", received: "2026-09-05T10:00:00Z"))
    @mailbox.add("sentitems", graph_message(id: "out", from: "info@sherpaholidays.com",
      to: "outbound@example.com", message_id: "<outbound@test>", received: "2026-09-06T10:00:00Z"))

    import = MailImport.create!(scope: "all", status: "draft")
    fail_next = true
    @mailbox.transport.on_get("/me/messages/out") do |*|
      raise Mail::ConnectionError, "interrupted" if fail_next

      { status: 200, json: @mailbox.find("out") }
    end
    assert_raises(Mail::ConnectionError) { Mail::PreviewJob.new.perform(import.id, fetcher: fetcher) }
    assert_equal "preview_failed", import.reload.status
    assert_equal 1, import.total_messages
    assert_equal "inbox|2026-09-05T10:00:00.000000Z", import.preview_json["preview_cursor"]

    fail_next = false
    @mailbox.instance_variable_get(:@messages)["inbox"].reject! { |message| message["id"] == "bulk-0" }
    Mail::PreviewJob.new.perform(import.id, fetcher: fetcher)
    assert_equal "preview", import.reload.status
    assert_equal 2, import.total_messages
    assert_equal %w[client@example.com outbound@example.com],
      import.preview_rows.map { |row| row["email"] }.sort
  end

  test "a resumed preview keeps mail sharing the cursor second and counts it once" do
    # Two messages arrive in the same second; Graph hands them back in an
    # order it never promised, and the walk dies between them.
    %w[AAAA ZZZZ].each do |id|
      @mailbox.add("inbox", graph_message(id: id, from: "#{id.downcase}@example.com",
        message_id: "<#{id}@test>", received: "2026-09-12T10:00:00Z"))
    end
    @mailbox.add("inbox", graph_message(id: "later", from: "later@example.com",
      message_id: "<later@test>", received: "2026-09-13T10:00:00Z"))

    import = MailImport.create!(scope: "all", status: "draft")
    fail_next = true
    @mailbox.transport.on_get("/me/messages/later") do |*|
      raise Mail::ConnectionError, "interrupted" if fail_next

      { status: 200, json: @mailbox.find("later") }
    end
    assert_raises(Mail::ConnectionError) { Mail::PreviewJob.new.perform(import.id, fetcher: fetcher) }
    assert_equal 2, import.reload.total_messages

    fail_next = false
    Mail::PreviewJob.new.perform(import.id, fetcher: fetcher)
    assert_equal "preview", import.reload.status
    assert_equal 3, import.total_messages
    counts = import.preview_rows.to_h { |row| [ row["email"], row["count"] ] }
    assert_equal({ "aaaa@example.com" => 1, "zzzz@example.com" => 1, "later@example.com" => 1 }, counts)
  end

  test "the history backfill covers archived mail that live sync never sees" do
    @mailbox.add("archive", graph_message(id: "filed", from: "operator@example.com",
      message_id: "<filed@test>", received: "2026-09-04T10:00:00Z"))
    @mailbox.add("clients", graph_message(id: "nested", from: "traveler@example.com",
      message_id: "<nested@test>", received: "2026-09-05T10:00:00Z"))
    @mailbox.add("deleteditems", graph_message(id: "binned", from: "binned@example.com",
      message_id: "<binned@test>", received: "2026-09-06T10:00:00Z"))

    import = MailImport.create!(scope: "all", status: "draft")
    Mail::PreviewJob.new.perform(import.id, fetcher: fetcher)
    assert_equal 2, import.reload.total_messages
    assert_equal %w[operator@example.com traveler@example.com],
      import.preview_rows.map { |row| row["email"] }.sort
  end

  test "preview never downloads attachment bytes" do
    @mailbox.add("inbox", graph_message(id: "with-file", from: "client@example.com",
      message_id: "<withfile@test>",
      attachments: [ graph_file_attachment(id: "p1", name: "itinerary.txt") ]),
      file_bytes: { "p1" => "itinerary bytes" })

    import = MailImport.create!(scope: "all", status: "draft")
    Mail::PreviewJob.new.perform(import.id, fetcher: fetcher)
    assert_equal 1, import.reload.total_messages
    assert_equal 0, @mailbox.byte_fetches
  end

  test "preview counts delivery headers and outbound mail but excludes personal mail" do
    client = Client.create!(name: "Remembered", email: "original@example.com")
    EmailIdentity.remember!("alternate@example.com", linkable: client)
    @mailbox.add("sentitems", graph_message(id: "m-remembered", from: "info@sherpaholidays.com",
      to: "alternate@example.com", message_id: "<remembered@test>"))
    @mailbox.add("inbox", graph_message(id: "m-personal", from: "friend@example.com",
      to: "captain@gmail.com", message_id: "<personal@test>"))
    %w[Delivered-To X-Original-To].each_with_index do |header, index|
      @mailbox.add("inbox", graph_message(id: "m-delivery-#{index}", from: "alias-sender@example.com",
        to: "captain@gmail.com", message_id: "<delivery#{index}@test>",
        headers: [ { "name" => header, "value" => "info@sherpaholidays.com" } ]))
    end
    @mailbox.add("inbox", graph_message(id: "m-bcc", from: "alias-sender@example.com",
      to: "manifest@example.com", message_id: "<bcc-preview@test>",
      headers: [ { "name" => "X-Envelope-To", "value" => "info@sherpaholidays.com" } ]))

    import = MailImport.create!(scope: "all", status: "draft")
    Mail::PreviewJob.new.perform(import.id, fetcher: fetcher)
    assert_equal 4, import.reload.total_messages
    rows = import.preview_rows.index_by { |row| row["email"] }
    assert_equal 3, rows.fetch("alias-sender@example.com")["count"]
    assert_equal 1, rows.fetch("alternate@example.com")["count"]
    assert rows.fetch("alternate@example.com")["duplicate"]
    assert_equal client.name, rows.fetch("alternate@example.com")["duplicate_name"]
    assert_not rows.key?("friend@example.com")
  end
end
