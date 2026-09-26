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
    lead = Lead.create!(name: "Ama Dorje", source: "google_ads", campaign_name: "ebc_search",
      received_at: Time.zone.local(2026, 9, 15, 10), trip_title: "Everest Base Camp", placement: "trip_page")
    AdSpend.record!(week_start: Date.new(2026, 9, 14), source: "google_ads", campaign_name: "ebc_search", amount_dollars: "126")

    mail = WeeklyReportMailer.weekly
    assert_equal [ "owner@example.com" ], mail.to
    assert_equal "SherpaHolidays ads, Sep 14-20: 1 inquiry, 0 qualified, 0 booked", mail.subject
    text = mail.text_part.body.decoded
    assert_includes text, "Goal: 10 travelers by Dec 31, 2026. So far 0. Need 0.7 a week for 15 weeks."
    assert_includes text, "Google ebc_search: $126 spend | 1 inq | 0 qual | 0 quoted | 0 booked | $126/inq"
    assert_includes text, "Meta: - spend | 0 inq"
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
  test "booked values flags and missing campaign spend render in both formats without ROAS" do
    Lead.create!(name: "Booker", source: "meta_ads", campaign_name: "social",
      perfectbook_contact_id: 42, received_at: Time.zone.local(2026, 9, 15))
    seen = Time.zone.local(2026, 9, 17)
    PerfectBook::Booking.create!(perfectbook_id: 1, perfectbook_contact_id: 42, status: "confirmed",
      party_size: 2, paid_minor: 50_000, total_minor: 700_000, first_paid_at: seen, synced_at: seen)
    mail = WeeklyReportMailer.weekly
    [ mail.text_part, mail.html_part ].each do |part|
      body = part.body.decoded
      assert_includes body, "$7,000 booked value"
      assert_includes body, "-/booking"
      assert_includes body, "ROAS -"
      assert_includes body, "Spend not entered for: Meta social."
      assert_includes body, "Flags:"
      assert_includes body, "Next review: Oct 10, 2026"
    end
    AdSpend.record!(week_start: Date.new(2026, 9, 14), source: "meta_ads", campaign_name: "social", amount_dollars: "200")
    mail = WeeklyReportMailer.weekly
    [ mail.text_part, mail.html_part ].each { |part| assert_includes part.body.decoded, "$200/booking" }
  end

  test "a rounded zero pace does not claim the goal is reached and unknown years omit the goal" do
    seen = Time.zone.local(2026, 1, 6)
    PerfectBook::Booking.create!(perfectbook_id: 1, perfectbook_contact_id: 99, status: "confirmed", party_size: 9,
      paid_minor: 50_000, first_paid_at: seen, synced_at: seen)
    mail = WeeklyReportMailer.weekly(week_start: Date.new(2026, 1, 5))
    [ mail.text_part, mail.html_part ].each do |part|
      assert_includes part.body.decoded, "So far 9."
      assert_not_includes part.body.decoded, "Goal reached"
    end
    mail = WeeklyReportMailer.weekly(week_start: Date.new(2028, 1, 3))
    [ mail.text_part, mail.html_part ].each { |part| assert_not_includes part.body.decoded, "Goal:" }
  end
end
