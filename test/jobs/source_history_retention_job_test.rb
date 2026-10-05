require "test_helper"

class SourceHistoryRetentionJobTest < ActiveJob::TestCase
  setup { Current.user_email = nil }
  teardown { Current.reset }

  test "new source backfill evidence and fit audits expire without deleting booking bindings or money" do
    now = Time.current
    lead = Lead.create!(name: "Synthetic booked lead", source: "google_ads", perfectbook_contact_id: 33,
      source_choice: "search", owner_fit_at_inquiry: "strong", received_at: now - 3.years,
      metadata: { "legacy_observed" => { "source" => "google_ads" } })
    lead.update_columns(last_touch_at: now - 3.years)
    booking = PerfectBook::Booking.create!(perfectbook_id: 55, perfectbook_contact_id: 33, first_received_at: now - 3.years,
      end_date: (now - 2.years).to_date, receipts_minor: 50000, net_received_minor: 50000, synced_at: now)
    BookingInquiryBinding.link!(booking, lead: lead, actor: "test", evidence: "Synthetic private review evidence")
    lead.activity_events.create!(kind: "source_backfill", summary: "Legacy source", occurred_at: now,
      metadata: { "new_value" => { "source" => "google_ads" } })
    SourceHistoryRetentionJob.perform_now(now: now)
    assert_equal "search", lead.reload.reported_source_code, "an explicitly paid binding has the booked seven-year horizon even before conversion"
    SourceHistoryRetentionJob.perform_now(now: now + 8.years)
    assert_nil lead.reload.metadata["legacy_observed"]
    assert_nil lead.owner_fit_at_inquiry
    assert_equal 0, lead.activity_events.where(kind: %w[source_backfill inquiry_fit booking_link]).count
    assert_equal "Source-link evidence expired", booking.reload.inquiry_binding.evidence
    assert_equal lead.id, booking.inquiry_binding.lead_id
    assert_equal 50000, booking.net_received_minor
  end

  test "retention of audits cannot change binding validity or erase report money on sync" do
    now = Time.zone.local(2026, 10, 5, 10)
    travel_to now
    %w[explicit inferred reviewed].each_with_index do |state, index|
      received = now - 8.years
      lead = Lead.create!(name: "Expired #{state}", source: "manual", perfectbook_contact_id: 70 + index,
        received_at: received, source_choice: "search")
      booking = PerfectBook::Booking.create!(perfectbook_id: 70 + index, perfectbook_contact_id: 70 + index,
        trip_id: 10, trip_name: "Past trip", departure_id: 20, start_date: received.to_date, end_date: received.to_date + 10,
        first_received_at: received, first_received_on: received.to_date, total_minor: 900_000,
        currency: "USD", cash_events_json: [ { "kind" => "receipt", "occurred_on" => received.to_date.iso8601,
          "currency" => "USD", "amount_minor" => 50_000 } ], synced_at: now)
      BookingInquiryBinding.link!(booking, lead: lead, actor: "test", evidence: "Expired personal statement", state: state)
      fingerprint = booking.inquiry_binding.upstream_fingerprint
      SourceHistoryRetentionJob.perform_now(now: now)
      assert_empty lead.activity_events.where(kind: "booking_link")
      assert_equal "Source-link evidence expired", booking.reload.inquiry_binding.evidence
      assert_equal fingerprint, booking.inquiry_binding.upstream_fingerprint
      BookingInquiryBinding.sync!(booking)
      assert_equal lead, booking.reload.primary_inquiry
      assert_equal state, booking.inquiry_binding.state
      report = WeeklyReport::Monthly.new(month: received.to_date.beginning_of_month)
      assert_equal index + 1, report.cohorts[:bookings]
      assert_equal({ "USD" => (index + 1) * 50_000 }, report.totals[:net_received])
      assert_equal({ "USD" => (index + 1) * 900_000 }, report.original_source_lifetime.sole[:booked_value])
      booking.update!(paid_minor: 100_000)
      BookingInquiryBinding.sync!(booking)
      assert_equal lead, booking.reload.primary_inquiry
    end
    booking = PerfectBook::Booking.find_by!(perfectbook_id: 72)
    booking.update!(departure_id: 21)
    BookingInquiryBinding.sync!(booking)
    assert_nil booking.reload.primary_inquiry
    assert_match(/evidence changed/, booking.binding_issue)
  end

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

  test "expired conversion keeps relationship events without source or campaign evidence" do
    now = Time.current
    first = Lead.create!(name: "Paid booker", source: "google_ads", campaign_name: "first-paid")
    client = first.convert_to_client!(expected_client_id: "new")
    returning = Lead.create!(name: "Repeat ask", existing_client: client, source: "meta_ads", campaign_name: "repeat-paid")
    returning.convert_to_client!(expected_client_id: client.id)
    events = client.activity_events.where(kind: "conversion").order(:id).to_a
    assert_equal "Returned as a lead from Meta ads", events.last.summary
    client.update_columns(created_at: now - 8.years)
    SourceHistoryRetentionJob.perform_now(now: now)
    assert_equal events.map(&:id), client.activity_events.where(kind: "conversion").order(:id).pluck(:id)
    events.each do |event|
      event.reload
      assert_not event.metadata.key?("source")
      assert_not event.metadata.key?("campaign")
      assert event.metadata["lead_id"].present?
    end
    assert_equal "Started as a lead", events.first.summary
    assert_equal "Returned as a lead", events.last.summary
    assert_equal "Converted to client", returning.activity_events.where(kind: "conversion").last.summary
  end

  test "recent receipts outweigh old departures for linked leads and clients" do
    now = Time.zone.local(2026, 10, 5, 10)
    %w[lead client].each_with_index do |kind, index|
      contact = 100 + index
      lead = Lead.create!(name: "Recent receipt #{kind}", perfectbook_contact_id: contact,
        received_at: now - 8.years, source_choice: "search")
      record = kind == "client" ? lead.convert_to_client! : lead
      record.update_columns(created_at: now - 8.years)
      lead.update_columns(last_touch_at: now - 8.years)
      SourceAnswers.record!(record, choice: "search", method: "website_form")
      old = PerfectBook::Booking.create!(perfectbook_id: 100 + index * 2, perfectbook_contact_id: contact,
        first_received_at: now - 8.years, end_date: (now - 8.years).to_date, synced_at: now)
      recent = PerfectBook::Booking.create!(perfectbook_id: 101 + index * 2, perfectbook_contact_id: contact,
        first_received_precision: "date", first_received_on: now.to_date - 1, synced_at: now)
      [ old, recent ].each { |item| BookingInquiryBinding.link!(item, lead: lead, actor: "test", evidence: "Reviewed receipt") }
      SourceHistoryRetentionJob.perform_now(now: now)
      assert_equal "search", record.reload.reported_source_code
      assert_equal 1, record.activity_events.where(kind: "source_answer").count
      assert_equal "Reviewed receipt", recent.reload.inquiry_binding.evidence
      SourceHistoryRetentionJob.perform_now(now: now + 8.years)
      assert record.reload.source_missing?
      assert_empty record.activity_events.where(kind: "source_answer")
    end
  end

  test "date-only paid bindings use the seven-year receipt horizon" do
    now = Time.zone.local(2026, 10, 5, 10)
    lead = Lead.create!(name: "Date-only booked", source: "manual", perfectbook_contact_id: 90,
      received_at: now - 8.years, source_choice: "search")
    lead.update_columns(last_touch_at: now - 8.years)
    booking = PerfectBook::Booking.create!(perfectbook_id: 90, perfectbook_contact_id: 90,
      first_received_precision: "date", first_received_on: (now - 3.years).to_date, synced_at: now)
    BookingInquiryBinding.link!(booking, lead: lead, actor: "test", evidence: "Reviewed receipt date")
    SourceHistoryRetentionJob.perform_now(now: now)
    assert_equal "search", lead.reload.reported_source_code
    SourceHistoryRetentionJob.perform_now(now: now + 5.years)
    assert lead.reload.source_missing?
    assert_nil booking.reload.first_received_at
  end

end
