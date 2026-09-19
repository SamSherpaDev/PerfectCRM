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

    # The composer hides behind the Reply pill on the phone and notes live
    # in its Note mode: open the pill, switch modes, then write.
    click_button "Reply"
    choose "Note", allow_label_click: true
    fill_in "Add a note", with: "Clicked the Everest ad"
    # The fixed phone tab bar can cover the button's click point after the
    # auto-scroll; center it first (same pattern as inbox_system_test.rb).
    save_note = find_button("Save note")
    save_note.scroll_to(save_note, align: :center)
    save_note.click
    assert_text "Clicked the Everest ad"
    assert_no_overflow("lead page after note")

    accept_confirm do
      click_button "Convert to client"
    end
    assert_selector "h1", text: "Ad Tashi"
    assert_text "Started as a lead"
    assert_no_overflow("converted client page")

    click_button "Details", exact: true
    click_link "open it"
    assert_text "Converted leads stay read-only."
    assert_no_button "Convert to client"
    assert_no_link "Edit"
    visit "#{page.current_path}/edit"
    assert_text "Converted leads stay read-only."
    assert_no_button "Save lead"
    assert_no_link "Edit"
  end

  test "delete archives with one confirmation and the archived tab restores" do
    OmniAuth.config.mock_auth[:google_oauth2] = OmniAuth::AuthHash.new(
      provider: "google_oauth2", uid: "google-captain",
      extra: { id_token: JWT.encode(@claims, @key, "RS256") }
    )
    Google::Auth::IDTokens.stub(:oidc_key_source, @source) do
      visit "/auth/google_oauth2/callback"
      assert_selector "h1", text: "Today"
    end
    page.current_window.resize_to(1400, 900)

    lead = Lead.create!(name: "Archive Tashi", source: "manual", status: "chatting")
    visit lead_path(lead)
    assert_selector "h1", text: "Archive Tashi"

    find("summary[aria-label='More actions']").click
    accept_confirm "Delete Archive Tashi? They move to the archive and can be restored from the Archived tab." do
      click_button "Delete lead"
    end
    assert_selector "h2", text: "Archived"
    assert_text "Archive Tashi"

    visit leads_path(tab: "chatting")
    assert_no_text "Archive Tashi"

    visit leads_path(tab: "archived")
    click_button "Restore"
    assert_selector "h1", text: "Archive Tashi"
    assert_link "Edit"
    visit leads_path(tab: "chatting")
    assert_text "Archive Tashi"
  end

  private

  def assert_no_overflow(context)
    width = page.evaluate_script("document.documentElement.scrollWidth")
    assert_operator width, :<=, 390, "#{context} overflows a 390px viewport (#{width}px)"
  end
end
