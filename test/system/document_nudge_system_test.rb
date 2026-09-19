require "application_system_test_case"
require_relative "../support/google_sign_in_test_helper"

class DocumentNudgeSystemTest < ApplicationSystemTestCase
  include GoogleSignInTestHelper

  test "booking nudge opens the prepared reply at 390px without an active template" do
    client = Client.create!(name: "Ama", email: "ama@example.com", perfectbook_contact_id: 7)
    Template.active.for_purpose(:document_request).update_all(archived_at: Time.current)
    PerfectBook::Booking.create!(perfectbook_id: 811, perfectbook_contact_id: 7,
      ref: "BK-11", trip_name: "Everest Base Camp", synced_at: Time.current,
      documents_json: { "travelers" => [
        { "id" => 3, "first_name" => "Ama", "documents" => [
          { "type" => "visa", "status" => "missing" },
          { "type" => "passport", "status" => "received" }
        ] }
      ], "missing_count" => 1 }, missing_count: 1)
    OmniAuth.config.mock_auth[:google_oauth2] = OmniAuth::AuthHash.new(
      provider: "google_oauth2", uid: "google-captain",
      extra: { id_token: JWT.encode(@claims, @key, "RS256") }
    )
    Google::Auth::IDTokens.stub(:oidc_key_source, @source) do
      visit "/auth/google_oauth2/callback"
      assert_selector "h1", text: "Today"
    end
    page.current_window.resize_to(390, 844)
    visit client_path(client)
    assert_selector ".reply-composer", visible: :hidden
    click_button "Files & dates"
    click_link "Nudge for missing documents"
    assert_selector ".reply-composer", visible: true
    assert_includes find_field("Message").value, "Ama: visa"
    assert_no_selector ".reply-pill", visible: true
    assert_operator page.evaluate_script("document.documentElement.scrollWidth"), :<=, 390
  end
end
