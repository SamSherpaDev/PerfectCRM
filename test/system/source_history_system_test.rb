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

  test "call details form records a connected call on its inquiry independently of source and tasks" do
    lead = Lead.create!(name: "Connected Screen", source: "manual")
    visit lead_path(lead)
    find("summary", text: "Add details", exact_text: true).click
    select "Talked", from: "Outcome"
    select "Inbound", from: "Direction"
    fill_in "Duration in seconds (optional)", with: "60"
    tolerate_submit_navigation { click_button "Save call" }
    tolerate_navigation_assertion { assert_text "Call logged: Talked." }
    within(".timeline") { assert_text "Call: Talked" }
    within(".calls-recent") { assert_text "Talked, they called" }
    call = lead.activity_events.find_by!(kind: "call")
    assert_equal({ "outcome" => "connected", "direction" => "inbound", "duration_seconds" => 60 },
      call.metadata.slice("outcome", "direction", "duration_seconds"))
    assert lead.reload.source_missing?
  end

  test "one tap logs an outbound call now and shows it under the buttons" do
    lead = Lead.create!(name: "Tap Screen", source: "manual")
    now = Time.current.change(usec: 0)
    travel_to now do
      visit lead_path(lead)
      within(".calls") { assert_text "No calls yet." }
      tolerate_submit_navigation { click_button "Voicemail" }
      assert_text "Call logged: Voicemail."
      within(".calls-recent li") { assert_text "Voicemail"; assert_text "Today #{now.strftime('%H:%M')}" }
      tolerate_submit_navigation { click_button "Talked" }
      tolerate_navigation_assertion { assert_text "Call logged: Talked." }
      within(".calls-recent") { assert_selector "li", count: 2 }
    end
    calls = lead.activity_events.where(kind: "call").order(:id)
    assert_equal %w[voicemail connected], calls.map { |call| call.metadata["outcome"] }
    assert_equal %w[outbound outbound], calls.map { |call| call.metadata["direction"] }
    assert_equal [ now ] * 2, calls.map(&:occurred_at)
  end

  test "one tap on the phone keeps the Details tab open with the logged call" do
    lead = Lead.create!(name: "Phone Tap", source: "manual")
    page.current_window.resize_to(390, 844)
    visit lead_path(lead)
    find("button[data-tab='details']").click
    tolerate_submit_navigation { click_button "No answer" }
    assert_text "Call logged: No answer."
    within(".calls-recent") { assert_text "No answer" }
    assert_selector "button[data-tab='details'][aria-current='true']"
    assert_operator page.evaluate_script("document.documentElement.scrollWidth"), :<=, 390
    assert_operator find_button("Talked").native.size.height, :>=, 44
  end
end
