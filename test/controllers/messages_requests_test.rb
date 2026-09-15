require "test_helper"
require_relative "../support/google_sign_in_test_helper"

class MessagesRequestsTest < ActionDispatch::IntegrationTest
  include GoogleSignInTestHelper
  include ActiveJob::TestHelper

  setup do
    @client = Client.create!(name: "Maya Gurung", email: "maya@example.com")
  end

  test "sending from the client page queues delivery and shows it sending" do
    sign_in
    assert_enqueued_with(job: OutboundDeliveryJob) do
      post client_messages_path(@client), params: {
        message: { to: "maya@example.com", subject: "Your trek", body: "Hello Maya" }
      }
    end
    assert_redirected_to client_path(@client)
    follow_redirect!
    assert_select ".flash-notice", text: /Sending/
    assert_select "#message-#{Message.last.id}", text: /Sending/
  end

  test "a send with no words keeps the draft and explains itself" do
    sign_in
    post client_messages_path(@client), params: {
      message: { to: "maya@example.com", subject: "Hi", body: "  " }
    }
    assert_redirected_to client_path(@client)
    follow_redirect!
    assert_select ".flash-alert", text: /Could not send/
    draft = Draft.where(owner: @client).last
    assert_equal "Hi", draft.subject
    assert_equal "maya@example.com", draft.to_addrs
  end

  test "converted leads stay read-only for sends" do
    lead = Lead.create!(name: "Old Ask", email: "old@example.com", source: "email")
    lead.convert_to_client!
    sign_in
    post lead_messages_path(lead), params: {
      message: { to: "old@example.com", subject: "Hi", body: "Hello" }
    }
    assert_redirected_to lead_path(lead)
    assert_equal 0, Message.count
  end

  test "failed messages retry from the timeline" do
    conversation = @client.conversations.create!(subject_line: "Hi")
    message = conversation.messages.create!(direction: "outbound", status: "failed",
      to_addrs: "maya@example.com", subject: "Hi", text_body: "Hello", send_error: "boom")
    sign_in
    assert_enqueued_with(job: OutboundDeliveryJob) do
      post retry_message_path(message)
    end
    assert_equal "queued", message.reload.status
  end

  test "attachments download for the captain, 404 without sign-in" do
    message = @client.conversations.create!(subject_line: "Hi").messages.create!(
      direction: "outbound", status: "sent",
      to_addrs: "maya@example.com", subject: "Hi", text_body: "Hello")
    message.files.attach(io: StringIO.new("hello"), filename: "hi.txt", content_type: "text/plain")
    get attachment_message_path(message, message.files.first.id)
    assert_redirected_to sign_in_path
    sign_in
    get attachment_message_path(message, message.files.first.id)
    assert_response :success
    assert_equal "hello", response.body
  end

  test "inbox thread shows messages with the reply box" do
    conversation = @client.conversations.create!(subject_line: "Your trek")
    conversation.messages.create!(direction: "outbound", status: "sent",
      to_addrs: "maya@example.com", subject: "Hi", text_body: "Hello")
    sign_in
    get inbox_thread_path(conversation)
    assert_response :success
    assert_select ".reply-ev", text: /Hello/
    assert_select ".reply-box", count: 1
  end

  test "reply box renders on client, lead, and organization pages" do
    lead = Lead.create!(name: "Tashi B", email: "tashi@example.com", source: "email")
    org = Organization.create!(name: "Adventure Co.", email: "a@example.com")
    sign_in
    get client_path(@client)
    assert_select ".reply-box", count: 1
    assert_select "[data-assist]", count: 1
    get lead_path(lead)
    assert_select ".reply-box", count: 1
    get organization_path(org)
    assert_select ".reply-box", count: 1
  end
end
