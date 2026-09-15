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
    assert_redirected_to client_path(@client, new_thread: 1)
    follow_redirect!
    assert_select ".flash-alert", text: /Could not send/
    draft = Draft.where(owner: @client).last
    assert_equal "Hi", draft.subject
    assert_equal "maya@example.com", draft.to_addrs
  end

  test "validation recovery preserves both saved and submitted draft attachments" do
    draft = Draft.create!(owner: @client, subject: "Hi", body: "Saved words")
    draft.files.attach(io: StringIO.new("saved bytes"), filename: "saved.txt", content_type: "text/plain")
    sign_in
    assert_no_difference("Message.count") do
      post client_messages_path(@client), params: {
        message: { to: @client.email, subject: "Hi", body: "  ",
          files: [ fixture_file_upload("test/fixtures/files/sample.txt", "text/plain") ] }
      }
    end
    assert_redirected_to client_path(@client, new_thread: 1)
    follow_redirect!
    assert_select "[aria-label='Draft attachments'] li", count: 2
    files = draft.reload.files.index_by { |file| file.filename.to_s }
    assert_equal [ "sample.txt", "saved.txt" ], files.keys.sort
    assert_equal "saved bytes", files["saved.txt"].download
    assert_equal File.read(Rails.root.join("test/fixtures/files/sample.txt")), files["sample.txt"].download
    post client_messages_path(@client), params: { message: { to: @client.email, subject: "Hi", body: "Corrected" } }
    assert_equal [ "sample.txt", "saved.txt" ], Message.last.files.map { |file| file.filename.to_s }.sort
  end

  test "validation failure reopens the submitted older conversation" do
    older = @client.conversations.create!(subject_line: "Older", last_message_at: 2.days.ago)
    newer = @client.conversations.create!(subject_line: "Newer", last_message_at: 1.day.ago)
    other_draft = newer.create_draft!(owner: @client, subject: "Other subject", body: "Other words")
    sign_in
    post client_messages_path(@client), params: {
      conversation_id: older.id,
      message: { to: "secondary@example.com", cc: "cc@example.com", subject: "Correct this reply", body: "  ",
        files: [ fixture_file_upload("test/fixtures/files/sample.txt", "text/plain") ] }
    }
    assert_redirected_to inbox_thread_path(older)
    follow_redirect!
    assert_select "input[name=conversation_id][value=?]", older.id.to_s
    assert_select "input[name='message[to]'][value='secondary@example.com']"
    assert_select "input[name='message[cc]'][value='cc@example.com']"
    assert_select "input[name='message[subject]'][value='Correct this reply']"
    assert_select "[aria-label='Draft attachments'] li", text: /sample.txt/
    assert_equal "  ", older.reload.draft.body
    assert_equal "Other words", other_draft.reload.body
  end

  test "validation failure reopens a new-message draft despite existing conversations" do
    conversation = @client.conversations.create!(subject_line: "Existing")
    other_draft = conversation.create_draft!(owner: @client, subject: "Existing reply", body: "Other words")
    sign_in
    post client_messages_path(@client), params: {
      message: { to: "new@example.com", subject: "New message attempt", body: "  ",
        files: [ fixture_file_upload("test/fixtures/files/sample.txt", "text/plain") ] }
    }
    assert_redirected_to client_path(@client, new_thread: 1)
    follow_redirect!
    assert_select "input[name=conversation_id][value]", count: 0
    assert_select "input[name='message[to]'][value='new@example.com']"
    assert_select "input[name='message[subject]'][value='New message attempt']"
    assert_select "[aria-label='Draft attachments'] li", text: /sample.txt/
    assert_equal "  ", Draft.find_by!(owner: @client, conversation_id: nil).body
    assert_equal "Other words", other_draft.reload.body
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
    message = conversation.messages.create!(direction: "out", status: "failed",
      to_addrs: "maya@example.com", subject: "Hi", text_body: "Hello", send_error: "boom")
    sign_in
    assert_enqueued_with(job: OutboundDeliveryJob) do
      post retry_message_path(message)
    end
    assert_equal "queued", message.reload.status
  end

  test "attachments download for the captain, 404 without sign-in" do
    message = @client.conversations.create!(subject_line: "Hi").messages.create!(
      direction: "out", status: "sent",
      to_addrs: "maya@example.com", subject: "Hi", text_body: "Hello")
    message.files.attach(io: StringIO.new("hello"), filename: "hi.txt", content_type: "text/plain")
    get attachment_path(message.files.first.id)
    assert_redirected_to sign_in_path
    sign_in
    get attachment_path(message.files.first.id)
    assert_response :success
    assert_equal "hello", response.body
  end

  test "inbox thread shows messages with the reply box" do
    conversation = @client.conversations.create!(subject_line: "Your trek")
    conversation.messages.create!(direction: "out", status: "sent",
      to_addrs: "maya@example.com", subject: "Hi", text_body: "Hello")
    sign_in
    get inbox_thread_path(conversation)
    assert_response :success
    assert_select ".stone", text: /Hello/
    assert_select ".reply-box", count: 1
  end

  test "reply box renders on client, lead, and organization pages" do
    lead = Lead.create!(name: "Tashi B", email: "tashi@example.com", source: "email")
    org = Organization.create!(name: "Adventure Co.", email: "a@example.com")
    sign_in
    get client_path(@client)
    assert_select ".reply-box", count: 1
    assert_select "[data-assist]", count: 0
    get lead_path(lead)
    assert_select ".reply-box", count: 1
    get organization_path(org)
    assert_select ".reply-box", count: 1
  end
end
