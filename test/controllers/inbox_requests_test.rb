require "test_helper"
require_relative "../support/google_sign_in_test_helper"

class InboxRequestsTest < ActionDispatch::IntegrationTest
  include GoogleSignInTestHelper

  setup do
    sign_in
  end

  test "index renders tabs with icons and counts" do
    client = Client.create!(name: "Tashi", email: "tashi@example.com")
    conversation = Conversation.create!(subject: "Everest", linkable: client, last_message_at: Time.current)
    conversation.messages.create!(direction: "in", from_address: "tashi@example.com",
      to_addresses: [ "info@sherpaholidays.com" ], subject: "Everest", sent_at: Time.current, text_body: "Hi")

    get inbox_path
    assert_response :success
    assert_select "nav.tabs a", text: /Waiting on you/
    assert_select "nav.tabs a", text: /Waiting on them/
    assert_select "nav.tabs a", text: /All/
    assert_select "nav.tabs a", text: /Triage/
    assert_select "a", text: /Everest/
  end

  test "triage tab shows suggested clients" do
    conversation = Conversation.create!(subject: "New ask", last_message_at: Time.current)
    conversation.messages.create!(direction: "in", from_address: "newbie@example.com",
      to_addresses: [ "info@sherpaholidays.com" ], subject: "New ask", sent_at: Time.current, text_body: "Hi")
    get inbox_path(tab: "triage")
    assert_response :success
    assert_select "a", text: /New ask/
  end

  test "thread view clears the unread mark" do
    client = Client.create!(name: "Maya", email: "maya@example.com")
    conversation = Conversation.create!(subject: "Dates", linkable: client, last_message_at: Time.current)
    conversation.messages.create!(direction: "in", from_address: "maya@example.com",
      to_addresses: [ "info@sherpaholidays.com" ], subject: "Dates", sent_at: Time.current, text_body: "When?")
    assert_equal 1, conversation.reload.unread_count

    get inbox_thread_path(conversation)
    assert_response :success
    assert_equal 0, conversation.reload.unread_count
    assert_select "article.stone-in", minimum: 1
  end

  test "client page shows the email stream" do
    client = Client.create!(name: "Stream", email: "stream@example.com")
    conversation = Conversation.create!(subject: "Stream sub", linkable: client, last_message_at: Time.current)
    conversation.messages.create!(direction: "in", from_address: "stream@example.com",
      to_addresses: [ "info@sherpaholidays.com" ], subject: "Stream sub", sent_at: Time.current, text_body: "hello stream")
    get client_path(client)
    assert_response :success
    assert_select "h2", text: "Email"
    assert_select "article.stone", minimum: 1
  end
  test "record timeline exposes older messages and the full expanded body" do
    client = Client.create!(name: "Long history", email: "history@example.com")
    21.times do |index|
      conversation = Conversation.create!(linkable: client, subject: "History #{index}")
      conversation.messages.create!(direction: "in", from_address: client.email, sent_at: index.minutes.ago,
        text_body: index.zero? ? "x" * 4100 + " final itinerary detail" : "message #{index}")
    end
    get client_path(client)
    assert_select "article.stone", count: 20
    assert_select "details", text: /final itinerary detail/
    older = css_select("a").find { |a| a.text == "Load older" }["href"]
    get older
    assert_response :success
    assert_select "article.stone", count: 1
    assert_select "article", text: /message 20/
  end

  test "inbox exposes the fifty first conversation" do
    51.times { |index| Conversation.create!(subject: "Page thread #{index}", last_message_at: index.minutes.ago) }
    get inbox_path(tab: "all")
    older = css_select("a").find { |a| a.text == "Load older" }["href"]
    get older
    assert_response :success
    assert_select "a", text: "Page thread 50"
  end

  test "sensitive attachment appears in triage even on a linked conversation" do
    client = Client.create!(name: "Review files", email: "review-files@example.com")
    parsed = Mail::Ingester.parse_raw("From: #{client.email}\r\nTo: info@sherpaholidays.com\r\nSubject: Passport review\r\n\r\nAttached")
    parsed.attachments << { filename: "passport.pdf", content_type: "application/pdf", data: "file" }
    result = Mail::Ingester.ingest(parsed: parsed, gmail: {})
    get inbox_path(tab: "triage")
    assert_response :success
    assert_select "a", text: "Passport review"
    get inbox_thread_path(result[:conversation])
    assert_select "button", text: "Remove from CRM, collect in PerfectBook"
  end

end
