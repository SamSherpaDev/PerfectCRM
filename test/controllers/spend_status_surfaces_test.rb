require "test_helper"
require_relative "../support/google_sign_in_test_helper"

class SpendStatusSurfacesTest < ActionDispatch::IntegrationTest
  include GoogleSignInTestHelper
  include SpendStatusHelper

  setup do
    sign_in
    travel_to Time.zone.local(2026, 10, 15, 10)
    @day = Date.new(2026, 10, 14)
    DailyAdSpend.create!(spent_on: @day, source: "google_ads", campaign_id: "123",
      campaign_name: "Synthetic campaign", currency: "USD", amount_minor: 0)
  end

  test "Channels and monthly and daily reports display the same coverage facts" do
    get channels_path
    assert_response :success
    assert_select ".channel-row[aria-labelledby=channel-google_ads] .spend-status", text: /1 of 14 campaign-days received, 13 missing/
    assert_select ".channel-row[aria-labelledby=channel-youtube] .spend-status", count: 0
    assert_select ".channel-row[aria-labelledby=channel-google_ads] a[href=?]",
      inquiry_costs_path(start_date: "2026-10-01", end_date: "2026-10-14"), text: "Review missing days"
    assert_select ".channel-row[aria-labelledby=channel-meta_ads] .spend-status", text: /never received/

    get inquiry_costs_path(start_date: "2026-10-01", end_date: "2026-10-14")
    assert_response :success
    assert_select ".spend-status", text: /1 of 14 campaign-days received, 13 missing/
    assert_select ".spend-status", text: /receipt time unavailable/
    assert_select ".spend-status", text: /Campaigns absent from both cannot be detected/

    get settings_weekly_report_path(month: "2026-10", view: "paid")
    assert_response :success
    assert_select "#monthly-sources-heading", text: "Where people come from"
    assert_select "section[aria-labelledby=monthly-sources-heading] .spend-status", text: /1 of 14 campaign-days received, 13 missing/
  end

  test "weekly preview and both Monday email formats share status calculations" do
    week = Date.new(2026, 10, 12)
    AdSpend.record!(week_start: week, source: "google_ads", campaign_name: "Synthetic campaign", amount_dollars: "0")
    Lead.create!(name: "Synthetic inquiry", source: "google_ads", campaign_name: "Missing campaign", received_at: @day.in_time_zone)
    summary = WeeklyReport::Summary.new(week_start: week)
    expected = summary.spend_statuses.map { |status| weekly_spend_status_line(status) } +
      summary.daily_spend_statuses.map { |status| daily_spend_status_line(status) }
    get settings_weekly_report_path(week: week.iso8601)
    assert_response :success
    preview = Nokogiri::HTML(response.body).at_css(".report-paper").text
    mail = WeeklyReportMailer.weekly(week_start: week, to: "demo@example.test")
    outputs = [ preview, mail.text_part.body.decoded, Nokogiri::HTML(mail.html_part.body.decoded).text ]
    outputs.each do |output|
      expected.each { |line| assert_includes output, line }
      assert_includes output, "Daily posts do not fill weekly spend"
      assert_includes output, "Missing campaign entries: Missing campaign"
    end
    assert_equal 1, summary.total.inquiries
    assert_equal 0, summary.total.qualified
    assert_nil summary.paid_total.spend_minor
  end

  test "Settings correction changes amount and receipt without moving the spend week" do
    attributes = { week_start: "2026-10-05", source: "meta_ads", campaign_name: "Synthetic", amount_dollars: "12" }
    post settings_ad_spends_path, params: { ad_spend: attributes }
    assert_response :see_other
    entry = AdSpend.sole
    travel 1.hour
    post settings_ad_spends_path, params: { ad_spend: attributes.merge(amount_dollars: "0") }
    assert_response :see_other
    assert_equal [ Date.new(2026, 10, 5), 0, Time.current ], entry.reload.attributes.values_at("week_start", "amount_minor", "last_posted_at")
    get edit_settings_path
    assert_response :success
    assert_select "#weekly-report-heading"
    assert_select "section[aria-labelledby=weekly-report-heading]", text: /Its spend dates stay in that week/
    assert_select "section[aria-labelledby=weekly-report-heading]", text: /Last posted Oct 15, 2026 at 11:00 PDT/
  end
end
