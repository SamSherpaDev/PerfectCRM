require "test_helper"
require_relative "../support/google_sign_in_test_helper"

class ReturningLeadsTest < ActionDispatch::IntegrationTest
  include GoogleSignInTestHelper
  setup { sign_in }

  test "conversion links matching clients and appends history" do
    [ :email, :perfectbook_contact_id ].each_with_index do |key, index|
      value = key == :email ? "return@example.com" : 987
      client = Client.create!(name: "Returning traveler", key => value, tag_list: "original", source: "referral")
      client.people.create!(name: "Existing person", email: "person#{index}@example.com")
      lead = Lead.create!(name: "New inquiry", key => value, source: "google_ads", campaign_name: "Spring", tag_list: "new")
      lead.people.create!(name: "Duplicate", email: "person#{index}@example.com")
      lead.people.create!(name: "Additional traveler")
      note = Note.create!(notable: lead, body: "Returning for Everest")
      get lead_path(lead)
      assert_select "form[data-turbo-confirm=?]", "This is an existing client: Returning traveler. Convert will attach this lead's history to them."
      assert_no_difference -> { Client.count } do
        post convert_lead_path(lead), params: { expected_client_id: client.id }
      end
      assert_redirected_to client_path(client)
      assert_equal client.id, lead.reload.converted_client_id
      assert_equal %w[new original], client.tags.reload.pluck(:name)
      assert_equal 2, client.people.count
      assert_equal "referral", client.reload.source
      assert_nil client.campaign_name
      copied = client.notes.find_by!(body: note.body)
      assert_equal [ copied.id ], client.activity_events.where(kind: "note").map { |event| event.metadata["note_id"] }
      event = client.activity_events.find_by!(summary: "Returned as a lead from Google ads")
      assert_equal "Spring", event.metadata["campaign"]
      get client_path(client)
      assert_select "div.callout", text: /Started as a lead/, count: 0
      get edit_lead_path(lead)
      assert_redirected_to lead_path(lead)
    end
  end
  test "PerfectBook identity wins when email matches a different client" do
    email_client = Client.create!(name: "Email client", email: "shared@example.com")
    booking_client = Client.create!(name: "Booking client", perfectbook_contact_id: 123)
    lead = Lead.create!(name: "Inquiry", email: " SHARED@example.com ", perfectbook_contact_id: 123)
    get lead_path(lead)
    assert_select "form[data-turbo-confirm=?]", "This is an existing client: Booking client. Convert will attach this lead's history to them."
    assert_no_difference -> { Client.count } do
      post convert_lead_path(lead), params: { expected_client_id: booking_client.id }
    end
    assert_redirected_to client_path(booking_client)
    assert_equal booking_client.id, lead.reload.converted_client_id
    assert_empty email_client.activity_events
  end

  test "a changed match requires reviewing the confirmation again" do
    lead = Lead.create!(name: "Inquiry", email: "return@example.com")
    get lead_path(lead)
    assert_select "input[name=expected_client_id][value=new]"
    client = Client.create!(name: "Returning", email: lead.email)
    assert_no_difference -> { Client.count + ActivityEvent.count } do
      post convert_lead_path(lead), params: { expected_client_id: "new" }
    end
    assert_redirected_to lead_path(lead)
    assert_not lead.reload.converted?
    assert_empty client.activity_events
  end

end
