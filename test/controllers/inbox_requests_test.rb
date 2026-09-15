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
end
