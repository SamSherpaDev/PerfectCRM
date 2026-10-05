require "application_system_test_case"
require_relative "../support/google_sign_in_test_helper"

class SourceHistorySystemTest < ApplicationSystemTestCase
  include GoogleSignInTestHelper

  setup do
    OmniAuth.config.mock_auth[:google_oauth2] = OmniAuth::AuthHash.new(
      provider: "google_oauth2", uid: "google-captain",
      extra: { id_token: JWT.encode(@claims, @key, "RS256") }
    )
    Google::Auth::IDTokens.stub(:oidc_key_source, @source) do
      visit "/auth/google_oauth2/callback"
      assert_selector "h1", text: "Today"
    end
    page.current_window.resize_to(1400, 900)
  end

  test "source is immediately editable at call start on desktop and phone without competing call form" do
    lead = Lead.create!(name: "Source Screen", email: "screen@example.com", source: "manual")
    visit lead_path(lead)
    assert_selector "details[open] summary", text: "Confirm source"
    assert_no_selector "select[name=outcome]", visible: true
    select "A friend or family member", from: "How did you first hear about SherpaHolidays?"
    fill_in "Short answer", with: "Alex"
    click_button "Save source"
    assert_text "Source saved."
    assert_text "Heard about us: A friend or family member"
    assert_text "Confirmed on the call."
    assert_no_selector "select[name=source_choice]", visible: true
    assert_equal 0, lead.activity_events.where(kind: "call").count
    assert_operator page.evaluate_script("document.documentElement.scrollWidth"), :<=, 1400

    phone_lead = Lead.create!(name: "Phone Source", source: "manual")
    page.current_window.resize_to(390, 844)
    visit lead_path(phone_lead)
    find("button[data-tab='details']").click
    assert_selector "details[open] summary", text: "Confirm source"
    select "I don't remember", from: "How did you first hear about SherpaHolidays?"
    click_button "Save source"
    assert_text "Source saved."
    find("button[data-tab='details']").click
    assert_text "Heard about us: I don't remember"
    assert_operator page.evaluate_script("document.documentElement.scrollWidth"), :<=, 390
    assert_equal "unsure", phone_lead.reload.source_answer_state
  end

  test "call form records a connected call on its inquiry independently of source and tasks" do
    lead = Lead.create!(name: "Connected Screen", source: "manual")
    visit lead_path(lead)
    find("summary", text: "Log a call", exact_text: true).click
    select "Connected", from: "Outcome"
    fill_in "Duration in seconds (optional)", with: "60"
    click_button "Save call"
    assert_text "Call saved."
    within(".timeline") { assert_text "Call: Connected" }
    assert_equal 1, lead.activity_events.where(kind: "call").count
    assert lead.reload.source_missing?
  end
end
