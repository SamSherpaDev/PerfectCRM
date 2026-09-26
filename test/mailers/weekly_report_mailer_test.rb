require "test_helper"

class WeeklyReportMailerTest < ActionMailer::TestCase
  setup do
    travel_to Time.zone.local(2026, 9, 21, 7)
    @old_allowlist = ENV["ALLOWED_GOOGLE_EMAILS"]
    ENV["ALLOWED_GOOGLE_EMAILS"] = "owner@example.com, other@example.com"
  end

  teardown do
    ENV["ALLOWED_GOOGLE_EMAILS"] = @old_allowlist
  end

  test "last week's numbers go to the captain in text and html" do
    Setting.current.update!(travelers_goal: 10)
    lead = Lead.create!(name: "Ama Dorje", source: "google_ads", campaign_name: "ebc_search",
      received_at: Time.zone.local(2026, 9, 15, 10), trip_title: "Everest Base Camp", placement: "trip_page")
    AdSpend.record!(week_start: Date.new(2026, 9, 14), source: "google_ads", campaign_name: "ebc_search", amount_dollars: "126")

    mail = WeeklyReportMailer.weekly
    assert_equal [ "owner@example.com" ], mail.to
    assert_equal "SherpaHolidays ads, Sep 14-20: 1 inquiry, 0 qualified, 0 booked", mail.subject
    text = mail.text_part.body.decoded
    assert_includes text, "Goal: 10 travelers by Dec 31, 2026. So far 0. Need 0.7 a week for 15 weeks."
    assert_includes text, "Google ebc_search: $126 spend | 1 inq | 0 qual | 0 quoted | 0 booked | $126/inq"
    assert_includes text, "Meta: 0 inq"
    assert_includes text, "Paid total: $126 spend | 1 inq"
    assert_includes text, "All sources: 1 inq | 0 qual | 0 quoted | 0 booked\n"
    assert_includes text, "Everest Base Camp: 1 inq, 0 qual, 0 booked"
    assert_includes text, "Came in from: trip page 1"
    assert_includes text, "1 inquiry waiting over 24 h"
    assert_includes text, "http://example.com/leads/#{lead.id}"
    html = mail.html_part.body.decoded
    assert_includes html, "SherpaHolidays ads, week of Sep 14-20"
    assert_includes html, "Google ebc_search"
    [ text, html, mail.subject ].each { |part| assert_not_includes part, "\u2014" }
  end

  test "asks for spend when the week has none and honors a saved recipient" do
    Setting.current.update!(weekly_report_recipient: "Reports@Example.com")

    mail = WeeklyReportMailer.weekly
    assert_equal [ "reports@example.com" ], mail.to
    assert_includes mail.text_part.body.decoded, "Spend not entered for this week yet."
  end
end
