require "test_helper"
require_relative "../support/google_sign_in_test_helper"

class SourceAnswersRequestsTest < ActionDispatch::IntegrationTest
  include GoogleSignInTestHelper
  setup { sign_in }

  test "source can be captured at call start without logging a connected call" do
    lead = Lead.create!(name: "Call Start", source: "manual")
    get lead_path(lead)
    assert_response :success
    assert_select "details[open] summary", text: "Confirm source"
    assert_select "select[name=source_choice] option[value=personal_referral]", text: "A friend or family member"
    assert_no_difference("ActivityEvent.where(kind: 'call').count") do
      post source_answers_path, params: { record_type: "Lead", record_id: lead.id, source_choice: "search", detail: "Google" }
    end
    assert_redirected_to lead_path(lead)
    assert_equal "search", lead.reload.reported_source_code
    assert_not_nil lead.source_confirmed_at
    assert_equal "call", lead.activity_events.where(kind: "source_answer").last.metadata["collection_method"]
    assert_no_difference("ActivityEvent.count") do
      post source_answers_path, params: { record_type: "Lead", record_id: lead.id, source_choice: "search", detail: "Google" }
    end
  end

  test "manual creation uses the shared source list without changing broad attribution" do
    post leads_path, params: { lead: { name: "Manual Source", source: "manual", source_choice: "facebook", reported_source_detail: "An ordinary post", capture_channel: "phone", is_test: "1" } }
    lead = Lead.order(:id).last
    assert_redirected_to lead_path(lead)
    assert_equal "facebook", lead.reported_source_code
    assert_equal "manual", lead.source
    assert_equal "phone", lead.capture_channel
    assert lead.is_test?
    assert_equal "answered", lead.source_answer_state
  end

  test "client and companion answers remain independent" do
    client = Client.create!(name: "Client")
    person = client.people.create!(name: "Companion")
    post source_answers_path, params: { record_type: "Client", record_id: client.id, source_choice: "search" }
    assert_redirected_to client_path(client)
    assert person.reload.source_missing?
    post source_answers_path, params: { record_type: "Person", record_id: person.id, source_choice: "unsure" }
    assert_redirected_to client_path(client)
    assert_equal "unsure", person.reload.source_answer_state
    assert_equal "search", client.reload.reported_source_code
    client.archive!
    assert_no_difference("ActivityEvent.count") do
      post source_answers_path, params: { record_type: "Person", record_id: person.id, source_choice: "youtube", correction_reason: "Remembered" }
    end
    assert_equal "unsure", person.reload.source_answer_state
  end

  test "client without an inquiry can start an explicitly linked phone inquiry" do
    client = Client.create!(name: "Existing Booker", email: "booker@example.com", source_choice: "personal_referral")
    get client_path(client)
    assert_response :success
    path = new_lead_path(existing_client_id: client.id, name: client.name, email: client.email, capture_channel: "phone")
    assert_select "a[href=?]", path, text: "New inquiry"
    get path
    assert_response :success
    assert_select "input[name='lead[existing_client_id]'][value=?]", client.id.to_s
    post leads_path, params: { lead: { name: client.name, email: client.email, existing_client_id: client.id, capture_channel: "phone", source_choice: "search" } }
    inquiry = Lead.order(:id).last
    assert_redirected_to lead_path(inquiry)
    assert_equal client, inquiry.existing_client
    assert_equal "phone", inquiry.capture_channel
    assert_equal "personal_referral", client.reload.reported_source_code
  end

  test "connected call retries bind only the selected inquiry for a client" do
    client = Client.create!(name: "Client")
    inquiry = Lead.create!(name: "Repeat", existing_client: client)
    another = Lead.create!(name: "Someone Else")
    body = { inquiry_id: inquiry.id, save_key: SecureRandom.uuid, occurred_at: Time.current.iso8601, outcome: "connected", direction: "outbound" }
    post client_calls_path(client), params: body
    assert_redirected_to client_path(client)
    assert_equal 1, inquiry.activity_events.where(kind: "call").count
    assert_no_difference("ActivityEvent.count") { post client_calls_path(client), params: body }
    post client_calls_path(client), params: body.merge(inquiry_id: another.id)
    assert_response :not_found
    assert_empty another.activity_events.where(kind: "call")
  end

  test "invalid calls fail without events and anonymous source updates require sign in" do
    lead = Lead.create!(name: "Invalid Call")
    assert_no_difference("ActivityEvent.count") do
      post lead_calls_path(lead), params: { save_key: SecureRandom.uuid, occurred_at: "bad", outcome: "connected", direction: "outbound" }
    end
    assert_redirected_to lead_path(lead)
    delete sign_out_path
    post source_answers_path, params: { record_type: "Lead", record_id: lead.id, source_choice: "search" }
    assert_redirected_to sign_in_path
    assert lead.reload.source_missing?
  end
end
