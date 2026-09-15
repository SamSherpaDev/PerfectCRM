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
end
