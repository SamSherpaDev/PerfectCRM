require "test_helper"

class CaptainDigestMailerTest < ActionMailer::TestCase
  setup do
    @old_allowlist = ENV["ALLOWED_GOOGLE_EMAILS"]
    ENV["ALLOWED_GOOGLE_EMAILS"] = "info@sherpaholidays.com"
    @client = Client.create!(name: "Maya", email: "maya@example.com", perfectbook_contact_id: 11)
  end

  teardown do
    ENV["ALLOWED_GOOGLE_EMAILS"] = @old_allowlist
  end

  test "morning lists overdue, today, and departures with deep links" do
    @client.tasks.create!(title: "Old nudge", due_on: Date.current - 1)
    @client.tasks.create!(title: "Today nudge", due_on: Date.current)
    PerfectBook::Booking.create!(perfectbook_id: 220, perfectbook_contact_id: 11,
      trip_name: "Everest", start_date: Date.current + 4, party_size: 2, synced_at: Time.current)

    mail = CaptainDigestMailer.morning
    assert_equal [ "info@sherpaholidays.com" ], mail.to
    assert_match(/overdue/i, mail.subject)
    body = mail.body.encoded
    assert_includes body, "Old nudge"
    assert_includes body, "Today nudge"
    assert_includes body, "Everest"
    helpers = Rails.application.routes.url_helpers
    assert_includes body, helpers.client_url(@client, host: "example.com")
    assert_includes body, helpers.root_url(host: "example.com")
  end

  test "morning with a clear desk says so" do
    body = CaptainDigestMailer.morning.body.encoded
    assert_includes body, "Nothing overdue"
    assert_includes body, "No follow-ups due today"
    assert_includes body, "Calls to make today: 0."
  end

  test "morning includes the full calls to make today count and links to Today" do
    travel_to Time.zone.local(2026, 10, 14, 7) do
      6.times { |i| Lead.create!(name: "Inquiry #{i}", phone_raw: "+1 415 555 010#{i}", received_at: 3.days.ago) }
      Lead.create!(name: "Recent inquiry", phone_raw: "+1 415 555 0109", received_at: 1.hour.ago)
      Lead.create!(name: "No phone inquiry", received_at: 3.days.ago)
      called = Lead.create!(name: "Called inquiry", phone_raw: "+1 415 555 0199", received_at: 3.days.ago)
      CallLog.record!(called, key: "digest-call-1", occurred_at: 1.day.ago,
        outcome: "connected", direction: "outbound")

      body = CaptainDigestMailer.morning.body.encoded
      assert_includes body, "Calls to make today: 7."
      assert_includes body, Rails.application.routes.url_helpers.root_url(host: "example.com")
    end
  end

  test "digest job sends when enabled and stays quiet when off" do
    assert_difference -> { ActionMailer::Base.deliveries.count }, 1 do
      TodayDigestJob.perform_now
    end
    Setting.current.update!(digest_enabled: false)
    assert_no_difference -> { ActionMailer::Base.deliveries.count } do
      TodayDigestJob.perform_now
    end
  end

  test "morning includes missed and upcoming scheduled calls with lead deep links" do
    travel_to Time.zone.local(2026, 10, 20, 7, 0) do
      missed_lead = Lead.create!(name: "Lakpa Sherpa")
      upcoming_lead = Lead.create!(name: "Dawa Geljen")
      missed_lead.scheduled_calls.create!(scheduled_at: Time.zone.local(2026, 10, 19, 15, 0), notes: "Confirm flights")
      upcoming_lead.scheduled_calls.create!(scheduled_at: Time.zone.local(2026, 10, 20, 11, 30), notes: "Discuss Langtang trek")
      @client.scheduled_calls.create!(scheduled_at: Time.zone.local(2026, 10, 20, 14, 0), notes: "Pre-departure check")

      body = CaptainDigestMailer.morning.body.encoded
      helpers = Rails.application.routes.url_helpers
      assert_includes body, "Missed calls (1):"
      assert_includes body, "Lakpa Sherpa · Oct 19 at 3:00 PM PT · Confirm flights"
      assert_includes body, helpers.lead_url(missed_lead, host: "example.com")
      assert_includes body, "Scheduled calls (2):"
      assert_includes body, "Dawa Geljen · Oct 20 at 11:30 AM PT · Discuss Langtang trek"
      assert_includes body, helpers.lead_url(upcoming_lead, host: "example.com")
      assert_includes body, "Maya · Oct 20 at 2:00 PM PT · Pre-departure check"
      assert_includes body, helpers.client_url(@client, host: "example.com")
    end
  end
end
