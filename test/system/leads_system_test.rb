require "application_system_test_case"
require_relative "../support/google_sign_in_test_helper"

# Leads live on the phone too: create, note, and convert must work at 390px.
class LeadsSystemTest < ApplicationSystemTestCase
  include GoogleSignInTestHelper

  test "create lead with note and convert at phone width" do
    OmniAuth.config.mock_auth[:google_oauth2] = OmniAuth::AuthHash.new(
      provider: "google_oauth2", uid: "google-captain",
      extra: { id_token: JWT.encode(@claims, @key, "RS256") }
    )
    Google::Auth::IDTokens.stub(:oidc_key_source, @source) do
      visit "/auth/google_oauth2/callback"
      assert_selector "h1", text: "Today"
    end
    page.current_window.resize_to(390, 844)

    visit leads_path
    assert_selector "h1", text: "Leads"
    assert_no_overflow("/leads")

    click_link "New lead"
    assert_selector "h1", text: "New lead"

    fill_in "Display name", with: "Ad Tashi"
    select "Google ads", from: "Source"
    fill_in "Campaign", with: "Everest Spring"
    click_button "Save lead"
    assert_selector "h1", text: "Ad Tashi"
    assert_no_overflow("lead page")

    fill_in "Add a note", with: "Clicked the Everest ad"
    click_button "Save note"
    assert_text "Clicked the Everest ad"
    assert_no_overflow("lead page after note")

    accept_confirm do
      click_button "Convert to client"
    end
    assert_selector "h1", text: "Ad Tashi"
    assert_text "Started as a lead"
    assert_no_overflow("converted client page")
  end

  private

  def assert_no_overflow(context)
    width = page.evaluate_script("document.documentElement.scrollWidth")
    assert_operator width, :<=, 390, "#{context} overflows a 390px viewport (#{width}px)"
  end
end
