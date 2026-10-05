require "test_helper"
require_relative "../support/google_sign_in_test_helper"

class SourceReportingRequestsTest < ActionDispatch::IntegrationTest
  include GoogleSignInTestHelper

  setup do
    @old_token = ENV["CHANNEL_CHECKS_TOKEN"]
    ENV["CHANNEL_CHECKS_TOKEN"] = "synthetic-check-token"
    @headers = { "Authorization" => "Bearer synthetic-check-token", "Content-Type" => "application/json" }
  end

  teardown { ENV["CHANNEL_CHECKS_TOKEN"] = @old_token }

  def spend(date: Date.yesterday, amount: 100)
    { spent_on: date.iso8601, source: "google_ads", campaign_id: "test-123", campaign_name: "Test", currency: "USD", amount_minor: amount }
  end

  test "daily spend auth is required and upserts stable campaign dates atomically" do
    post "/api/v1/channels/daily_spend", params: { spends: [ spend ] }.to_json, headers: { "Content-Type" => "application/json" }
    assert_response :unauthorized
    assert_no_difference "DailyAdSpend.count" do
      post "/api/v1/channels/daily_spend", params: { spends: [ spend, spend(amount: -1) ] }.to_json, headers: @headers
      assert_response :unprocessable_entity
    end
    post "/api/v1/channels/daily_spend", params: { spends: [ spend ] }.to_json, headers: @headers
    assert_response :created
    post "/api/v1/channels/daily_spend", params: { spends: [ spend(amount: 0).merge(campaign_name: "Renamed") ] }.to_json, headers: @headers
    assert_response :created
    assert_equal [ 1, 0, "Renamed" ], [ DailyAdSpend.count, DailyAdSpend.first.amount_minor, DailyAdSpend.first.campaign_name ]
    post "/api/v1/channels/daily_spend", params: { spends: [ spend(date: Date.current) ] }.to_json, headers: @headers
    assert_response :unprocessable_entity
  end

  test "signed in month selector and missing source link render" do
    sign_in
    get settings_weekly_report_path(month: "2026-10", view: "paid")
    assert_response :success
    assert_select "h2", text: "Where people come from"
    assert_select "input[type=month]"
    assert_select "a", text: "Review missing sources"
    assert_includes response.body, "As of"
    assert_includes response.body, "Q-fit"
    assert_includes response.body, "Platform-qualified"
    assert_includes response.body, "Recognized revenue: unavailable"
  end

  test "booking link requires signed-in review and matching exact contact with audit reason" do
    lead = Lead.create!(name: "Synthetic", source: "manual", perfectbook_contact_id: 55)
    other = Lead.create!(name: "Other synthetic", source: "manual", perfectbook_contact_id: 99)
    booking = PerfectBook::Booking.create!(perfectbook_id: 8, perfectbook_contact_id: 55, synced_at: Time.current)
    post booking_inquiry_bindings_path(booking_id: booking.id), params: { binding: { lead_id: lead.id, reason: "Checked trip" } }
    assert_redirected_to sign_in_path
    sign_in
    post booking_inquiry_bindings_path(booking_id: booking.id), params: { binding: { lead_id: other.id, reason: "Checked trip" } }
    assert_nil booking.reload.primary_inquiry
    post booking_inquiry_bindings_path(booking_id: booking.id), params: { binding: { lead_id: lead.id, reason: "" } }
    assert_nil booking.reload.primary_inquiry
    post booking_inquiry_bindings_path(booking_id: booking.id), params: { binding: { lead_id: lead.id, reason: "Checked contact trip and dates" } }
    assert_redirected_to lead_path(lead)
    assert_equal lead, booking.reload.primary_inquiry
    event = lead.activity_events.find_by!(kind: "booking_link")
    assert_equal "Checked contact trip and dates", event.metadata["evidence"]
    assert_equal "reviewed", booking.inquiry_binding.state
  end
end
