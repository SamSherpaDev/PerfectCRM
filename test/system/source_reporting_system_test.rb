require "application_system_test_case"
require_relative "../support/google_sign_in_test_helper"

class SourceReportingSystemTest < ApplicationSystemTestCase
  include GoogleSignInTestHelper

  setup do
    OmniAuth.config.mock_auth[:google_oauth2] = OmniAuth::AuthHash.new(
      provider: "google_oauth2", uid: "google-captain", extra: { id_token: JWT.encode(@claims, @key, "RS256") })
    Google::Auth::IDTokens.stub(:oidc_key_source, @source) do
      visit "/auth/google_oauth2/callback"
      assert_selector "h1", text: "Today"
    end
    page.current_window.resize_to(1400, 900)
  end

  test "monthly sources and cohorts are usable at desktop and 390px without page overflow" do
    lead = Lead.create!(name: "Synthetic report", source: "manual", perfectbook_contact_id: 55, received_at: 2.days.ago)
    booking = PerfectBook::Booking.create!(perfectbook_id: 55, perfectbook_contact_id: 55, first_received_at: 1.day.ago,
      first_received_on: Date.yesterday, first_received_precision: "date", traveler_count: 3,
      total_minor: 900_000, receipts_minor: 50_000, currency: "USD", synced_at: Time.current)
    BookingInquiryBinding.link!(booking, lead: lead, actor: "test", evidence: "Synthetic evidence")
    [ 1400, 390 ].each do |width|
      page.current_window.resize_to(width, 900)
      visit settings_weekly_report_path
      assert_selector "h2", text: "Where people come from"
      assert_text "As of"
      select "Inquiry paid-performance touch", from: "Source view"
      click_button "View", exact: true
      assert_text "Ad cost / booking"
      find("summary", text: "Inquiry cohort and completeness").click
      assert_text "Within 30 days"
      assert_text "inquiry identities unresolved"
      assert_operator page.evaluate_script("document.documentElement.scrollWidth"), :<=, width
    end
  end

  test "inquiry link review and settings prerequisites stay quiet on phone" do
    lead = Lead.create!(name: "Synthetic link", source: "manual", perfectbook_contact_id: 55)
    PerfectBook::Booking.create!(perfectbook_id: 55, perfectbook_contact_id: 55, ref: "BK-55", synced_at: Time.current)
    visit lead_path(lead)
    find("summary", text: "Review inquiry link").click
    select "#{lead.reference} · #{lead.name}", from: "Purchasing inquiry"
    fill_in "Evidence and reason", with: "Checked contact and trip"
    click_button "Confirm inquiry link"
    assert_text "Booking inquiry link reviewed."
    assert_text "Primary inquiry: #{lead.reference}"
    page.current_window.resize_to(390, 844)
    visit edit_settings_path(anchor: "ad-conversions-heading")
    assert_text "Meta terms confirmation"
    assert_text "Google terms confirmation"
    assert_no_selector "span.badge", text: "Meta configured"
    assert_operator page.evaluate_script("document.documentElement.scrollWidth"), :<=, 390
  end
end
