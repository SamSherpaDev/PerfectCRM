require "test_helper"
require_relative "../support/google_sign_in_test_helper"

class DraftsRequestsTest < ActionDispatch::IntegrationTest
  include GoogleSignInTestHelper

  setup do
    @client = Client.create!(name: "Maya Gurung", email: "maya@example.com")
  end

  test "save draft persists per conversation and confirms" do
    sign_in
    conversation = @client.conversations.create!(subject_line: "Your trek")
    patch client_draft_path(@client), params: {
      conversation_id: conversation.id,
      message: { to: "maya@example.com", subject: "Your trek", body: "Half written…" }
    }
    assert_redirected_to client_path(@client)
    draft = conversation.reload.draft
    assert_equal "Half written…", draft.body
    follow_redirect!
    assert_select "#draft-status", text: /Draft saved/
  end

  test "save draft answers turbo streams for the inline status" do
    sign_in
    patch client_draft_path(@client),
      params: { message: { subject: "Hi", body: "words" } },
      headers: { "Accept" => "text/vnd.turbo-stream.html" }
    assert_response :success
    assert_match(/Draft saved/, response.body)
  end

  test "an emptied draft clears itself" do
    conversation = @client.conversations.create!(subject_line: "Hi")
    draft = conversation.create_draft!(owner: @client, body: "words")
    sign_in
    patch client_draft_path(@client), params: {
      conversation_id: conversation.id, message: { subject: "", body: "" }
    }
    assert_not Draft.exists?(draft.id)
  end
end
