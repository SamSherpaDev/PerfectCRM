require "test_helper"

class SourceHistoryRetentionJobTest < ActiveJob::TestCase
  setup { Current.user_email = nil }
  teardown { Current.reset }

  test "detailed clicks and URLs expire at 180 days without removing the answer or coarse source" do
    now = Time.current
    lead = Lead.create!(name: "Retention Example", received_at: now - 181.days, metadata: {
      "attribution" => { "gclid" => "old-click" }, "page" => { "url" => "https://example.com" },
      "acquisition" => { "first_touch" => { "gclid" => "old-click", "fbclid" => "old-meta", "landing_url" => "https://example.com", "referrer_host" => "example.com", "source" => "google_ads" } }
    })
    SourceAnswers.record!(lead, choice: "search", detail: "Google", method: "website_form")
    SourceHistoryRetentionJob.perform_now(now: now)
    assert_equal "search", lead.reload.reported_source_code
    assert_nil lead.metadata["attribution"]
    assert_nil lead.metadata["page"]
    assert_equal({ "source" => "google_ads" }, lead.metadata.dig("acquisition", "first_touch"))
    assert_equal 1, lead.activity_events.where(kind: "source_answer").count
  end

  test "unbooked source history expires after 24 months of substantive inactivity even when archived" do
    now = Time.current
    lead = Lead.create!(name: "Archived Source", received_at: now - 25.months, archived_at: now)
    SourceAnswers.record!(lead, choice: "personal_referral", detail: "Alex", method: "website_form")
    person = lead.people.create!(name: "Companion")
    SourceAnswers.record!(person, choice: "instagram", method: "website_form")
    CallLog.record!(lead, key: SecureRandom.uuid, occurred_at: now - 25.months, direction: "outbound", outcome: "connected")
    lead.update_columns(last_touch_at: now - 25.months)
    SourceHistoryRetentionJob.perform_now(now: now)
    assert lead.reload.source_missing?
    assert_nil lead.reported_source_detail
    assert person.reload.source_missing?
    assert_empty lead.activity_events.where(kind: %w[source_answer call])
    assert_equal "Archived Source", lead.name
    assert lead.archived?
  end

  test "new substantive contact and recent booking retain discovery while old booked source expires at seven years" do
    now = Time.current
    lead = Lead.create!(name: "Recent Contact", received_at: now - 25.months)
    SourceAnswers.record!(lead, choice: "youtube", method: "website_form")
    lead.update_columns(last_touch_at: now - 1.month)
    client = Client.create!(name: "Booked", perfectbook_contact_id: 42)
    SourceAnswers.record!(client, choice: "search", method: "website_form")
    client.update_columns(created_at: now - 8.years)
    assert_operator client.last_activity_at, :>, now - 1.day
    booking = PerfectBook::Booking.create!(perfectbook_id: 42, perfectbook_contact_id: 42, end_date: (now - 6.years).to_date, synced_at: now)
    SourceHistoryRetentionJob.perform_now(now: now)
    assert_equal "youtube", lead.reload.reported_source_code
    assert_equal "search", client.reload.reported_source_code
    booking.update!(end_date: (now - 8.years).to_date)
    SourceHistoryRetentionJob.perform_now(now: now)
    assert client.reload.source_missing?
    assert_equal "Booked", client.name
  end
  test "expired returning inquiry removes copied calls while retaining client discovery" do
    now = Time.current
    client = Client.create!(name: "Returning")
    SourceAnswers.record!(client, choice: "search", method: "website_form")
    lead = Lead.create!(name: "Old inquiry", existing_client: client, received_at: now - 25.months)
    CallLog.record!(lead, key: SecureRandom.uuid, occurred_at: now - 25.months, direction: "outbound", outcome: "connected")
    lead.update_columns(last_touch_at: now - 25.months)
    assert_equal 1, client.activity_events.where(kind: "call").count
    SourceHistoryRetentionJob.perform_now(now: now)
    assert_empty client.activity_events.where(kind: "call")
    assert_equal "search", client.reload.reported_source_code
  end

end
