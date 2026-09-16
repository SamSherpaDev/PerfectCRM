require "test_helper"
require_relative "../support/google_sign_in_test_helper"

class TriageRequestsTest < ActionDispatch::IntegrationTest
  include GoogleSignInTestHelper

  setup do
    sign_in
  end

  def triage_conversation(sender: "newbie@example.com")
    conversation = Conversation.create!(subject: "Ask", last_message_at: Time.current)
    conversation.messages.create!(direction: "in", from_address: sender,
      to_addresses: [ "info@sherpaholidays.com" ], subject: "Ask", sent_at: Time.current, text_body: "Hi")
    conversation
  end

  test "link to existing remembers the identity for later mail" do
    client = Client.create!(name: "Existing", email: "other@example.com")
    conversation = triage_conversation
    post link_conversation_path(conversation), params: { linkable_type: "Client", linkable_id: client.id }
    assert_redirected_to inbox_thread_path(conversation)
    assert_equal client, conversation.reload.linkable
    assert_equal client, EmailIdentity.find_for("newbie@example.com")&.linkable
  end

  test "ignore sender remembers and hides the thread" do
    conversation = triage_conversation
    post ignore_conversation_path(conversation)
    assert conversation.reload.ignored?
    assert EmailIdentity.find_for("newbie@example.com")&.ignored?
  end

  test "create client from triage links and redirects" do
    conversation = triage_conversation(sender: "fresh@example.com")
    assert_difference("Client.count", 1) do
      post make_client_conversation_path(conversation)
    end
    assert conversation.reload.linkable.is_a?(Client)
  end

  test "create lead and organization from triage" do
    conversation = triage_conversation(sender: "leadme@example.com")
    assert_difference("Lead.count", 1) do
      post make_lead_conversation_path(conversation)
    end
    conversation2 = triage_conversation(sender: "org@example.com")
    assert_difference("Organization.count", 1) do
      post make_organization_conversation_path(conversation2)
    end
  end
  test "manual lead choices resolve converted leads to their client" do
    lead = Lead.create!(name: "Converted", email: "converted-triage@example.com", source: "email")
    client = lead.convert_to_client!
    conversation = triage_conversation(sender: lead.email)
    assert_no_difference("Lead.count") { post make_lead_conversation_path(conversation) }
    assert_equal client, conversation.reload.linkable
    assert_equal client, EmailIdentity.find_for(lead.email).linkable
    assert_redirected_to client_path(client)

    other = triage_conversation(sender: "another-triage@example.com")
    post link_conversation_path(other), params: { linkable_type: "Lead", linkable_id: lead.id }
    assert_equal client, other.reload.linkable
    assert_equal client, EmailIdentity.find_for("another-triage@example.com").linkable
  end

  test "Bcc only outbound mail can create a client from triage" do
    parsed = Mail::Ingester.parse_raw("From: info@sherpaholidays.com\r\nBcc: hidden@example.com\r\nSubject: Private invitation\r\n\r\nHello")
    conversation = Mail::Ingester.ingest(parsed: parsed, provider: {})[:conversation]
    get inbox_thread_path(conversation)
    assert_response :success
    assert_select "button", text: "Create client"
    post make_client_conversation_path(conversation)
    client = Client.find_by!(email: "hidden@example.com")
    assert_equal client, conversation.reload.linkable
    assert_redirected_to client_path(client)
  end
end
