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
    assert_match(/biz$/, import.preview_json["preview_cursor"].to_s)

    fail_next = false
    @mailbox.instance_variable_get(:@messages)["inbox"].reject! { |message| message["id"] == "bulk-0" }
    Mail::PreviewJob.new.perform(import.id, fetcher: fetcher)
    assert_equal "preview", import.reload.status
    assert_equal 2, import.total_messages
    assert_equal %w[client@example.com outbound@example.com],
      import.preview_rows.map { |row| row["email"] }.sort
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
      headers: [ { "name" => "Received",
        "value" => "from mx.example by outlook.com for <info@sherpaholidays.com>" } ]))

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
