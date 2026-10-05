require "test_helper"

class SourceReportingTest < ActiveSupport::TestCase
  setup do
    @now = Time.zone.local(2026, 11, 5, 10)
    travel_to @now
    @lead = Lead.create!(name: "Synthetic booker", email: "source@example.test", source: "google_ads",
      perfectbook_contact_id: 44, trip_interest: "Test trip", received_at: Time.zone.local(2026, 10, 1, 10),
      owner_fit_at_inquiry: "strong", fit_band: "strong", source_choice: "personal_referral",
      metadata: { "acquisition" => { "permission" => { "state" => "allowed", "measurement" => true, "sharing" => true },
        "first_touch" => { "observed_at" => "2026-10-01T16:00:00Z", "source" => "instagram" },
        "last_non_direct_touch" => { "observed_at" => "2026-10-01T16:00:00Z", "source" => "google_ads", "gclid" => "synthetic-click", "campaign_id" => "123", "utm_campaign" => "Old name" } } })
  end

  def booking(id: 51, receipt: Time.zone.local(2026, 10, 15, 9), **attrs)
    cash = [ { "id" => "receipt-#{id}", "kind" => "receipt", "occurred_at" => receipt.iso8601,
      "occurred_on" => receipt.to_date.iso8601, "time_precision" => "timestamp", "amount_minor" => 50_000, "currency" => "USD" } ]
    PerfectBook::Booking.create!({ perfectbook_id: id, perfectbook_contact_id: 44, ref: "BK-#{id}",
      crm_inquiry_ref: @lead.reference, first_received_at: receipt, first_received_on: receipt.to_date,
      first_received_precision: "timestamp", traveler_count: 3, total_minor: 900_000, receipts_minor: 50_000,
      refunds_minor: 0, net_received_minor: 50_000, paid_minor: 50_000, currency: "USD", status: "confirmed",
      cash_events_json: cash, synced_at: @now, trip_name: "Test trip" }.merge(attrs)).tap { |item| BookingInquiryBinding.link!(item, lead: @lead, actor: "test", evidence: "Reviewed trip") if item.crm_inquiry_ref.present? }
  end

  test "binding is unique and a later inquiry cannot take historical credit" do
    item = booking
    client = @lead.convert_to_client!
    other = Lead.create!(name: "Repeat inquiry", source: "meta_ads", existing_client: client, received_at: @now)
    summary = WeeklyReport::Summary.new(week_start: Date.new(2026, 10, 12))
    assert_equal @lead, item.primary_inquiry
    assert_equal 1, summary.rows.find { |row| row.source == "google_ads" }.booked
    assert_nil AdConversions.paid_booking(other)
    assert_raises(ArgumentError) { BookingInquiryBinding.link!(item, lead: other, actor: "test", evidence: "review") }
    item.update!(crm_inquiry_ref: other.reference)
    BookingInquiryBinding.sync!(item)
    assert_match(/changed/, item.binding_issue)
    assert_equal @lead.id, item.inquiry_binding.lead_id
    assert_nil item.primary_inquiry
  end

  test "one booking exports once and repeat bookings get their own Purchase IDs" do
    first = booking(receipt: @now - 1.day)
    second = booking(id: 52, receipt: @now - 2.hours)
    rows = AdConversions.record!(@lead).select { |row| row.event == "booked" }
    assert_equal [ 51, 52 ], rows.map(&:perfectbook_id)
    assert_equal [ "sh-booking-51-purchase", "sh-booking-52-purchase" ], rows.map(&:event_id)
    assert_equal first.first_received_at, rows.first.occurred_at
    first.update!(paid_minor: 900_000, receipts_minor: 900_000)
    assert_empty AdConversions.record!(@lead)
    assert_equal 2, AdConversion.where(event: "booked").count
    assert_equal second, AdConversions.paid_bookings(@lead).last
  end

  test "a previously exported unbound legacy Purchase cannot replay under a new booking event ID" do
    AdConversion.insert_all!([ { lead_id: @lead.id, event: "booked", event_id: "legacy-purchase", occurred_at: @now - 1.day,
      value_minor: 3000, delivery_status: "accepted", meta_status: "sent", meta_attempts: 1, meta_sent_at: @now - 1.day, created_at: @now - 1.day, updated_at: @now - 1.day } ])
    booking(receipt: @now - 2.days)
    row = AdConversions.record!(@lead).find { |event| event.event == "booked" }
    assert_equal :skipped, AdConversions.deliver_meta!(row)
    assert_match(/Legacy Purchase/, row.reload.last_skip_reason)
    assert_not AdConversions::GoogleFeed.servable?(row, @now)
    assert_match(/Legacy Purchase/, row.reload.google_skip_reason)
    # A genuinely later repeat receipt cannot have been the old recorded outcome.
    booking(id: 52, receipt: @now - 1.hour)
    future = AdConversions.record!(@lead).find { |event| event.event == "booked" }
    assert_nil AdConversions.booking_skip_reason(future)
    assert AdConversions::GoogleFeed.servable?(future, @now)
    assert_nil AdConversion.find_by!(event_id: "legacy-purchase").perfectbook_id
  end

  test "date-only receipts and inferred links do not create ad events" do
    item = booking(first_received_precision: "date")
    assert_not_includes AdConversions.record!(@lead).map(&:event), "booked"
    item.update!(first_received_precision: "timestamp")
    item.inquiry_binding.update!(state: "inferred")
    assert_not_includes AdConversions.record!(@lead).map(&:event), "booked"
  end

  test "expired clicks are withheld with visible reasons and real event time" do
    item = booking(receipt: @now - 1.day)
    data = @lead.metadata.deep_dup
    data["acquisition"]["last_non_direct_touch"]["observed_at"] = (@now - 91.days).iso8601
    @lead.update!(metadata: data)
    row = AdConversions.record!(@lead).find { |outcome| outcome.event == "booked" }
    assert_equal item.first_received_at, row.occurred_at
    assert_not AdConversions::GoogleFeed.servable?(row, @now)
    assert_match(/Expired click/, row.reload.google_skip_reason)
  end

  test "legacy unbound Purchase rows never export and no click time is fabricated" do
    row = AdConversion.create!(lead: @lead, event: "qualified", event_id: "test-qualified", occurred_at: @now, value_minor: 1000, google: true)
    @lead.update!(metadata: { "attribution" => { "gclid" => "old" }, "acquisition" => { "permission" => { "state" => "allowed", "measurement" => true, "sharing" => true } } })
    assert_nil AdConversions.click_at(@lead)
    assert_not AdConversions::GoogleFeed.servable?(row, @now)
    assert_equal "Click observation time missing", row.reload.google_skip_reason
  end

  test "monthly source alternatives reconcile group bookings refunds and currencies" do
    item = booking(cancelled_at: Time.zone.local(2026, 10, 20), status: "cancelled")
    item.update!(cash_events_json: item.cash_events + [
      { "id" => "refund-1", "kind" => "refund", "occurred_on" => "2026-10-20", "time_precision" => "date", "amount_minor" => 10_000, "currency" => "USD" },
      { "id" => "receipt-eur", "kind" => "receipt", "occurred_on" => "2026-10-31", "time_precision" => "date", "amount_minor" => 20_000, "currency" => "EUR" } ])
    CallLog.record!(@lead, key: "connected-test", occurred_at: Time.zone.local(2026, 10, 2), outcome: "connected", direction: "outbound")
    CallLog.record!(@lead, key: "connected-test", occurred_at: Time.zone.local(2026, 10, 2), outcome: "connected", direction: "outbound")
    @lead.activity_events.create!(kind: "stage_change", occurred_at: Time.zone.local(2026, 10, 3), summary: "Chat", metadata: { "to" => "chatting", "actor" => "captain" })
    expected = nil
    %w[reported paid first].each do |view|
      report = WeeklyReport::Monthly.new(month: Date.new(2026, 10, 1), view: view)
      expected ||= report.totals
      assert_equal expected, report.totals
      assert_equal({ "USD" => 40_000, "EUR" => 20_000 }, report.totals[:net_received])
      row = report.rows.find { |candidate| candidate.booked == 1 }
      assert_equal [ 1, 1, 3, 1, 1, 1 ], [ row.inquiries, row.connected_calls, row.travelers, row.cancelled, row.q_fit, row.platform_qualified ]
    end
  end

  test "spend requires every exact date and stable campaign ID with no weekly proration" do
    booking
    report = -> { WeeklyReport::Monthly.new(month: Date.new(2026, 10, 1), view: "paid") }
    AdSpend.record!(week_start: Date.new(2026, 9, 28), source: "google_ads", campaign_name: "Old name", amount_dollars: "700")
    assert_nil report.call.rows.find { |row| row.booked == 1 }.spend
    (Date.new(2026, 10, 1)..Date.new(2026, 10, 30)).each do |date|
      DailyAdSpend.record!(spent_on: date, source: "google_ads", campaign_id: "123", campaign_name: "Renamed", currency: "USD", amount_minor: 100)
    end
    assert_nil report.call.rows.find { |row| row.booked == 1 }.spend
    DailyAdSpend.record!(spent_on: Date.new(2026, 10, 31), source: "google_ads", campaign_id: "123", campaign_name: "Renamed", currency: "USD", amount_minor: 0)
    row = report.call.rows.find { |candidate| candidate.booked == 1 }
    assert_equal({ "USD" => 3000 }, row.spend)
    assert_equal({ "USD" => 3000 }, row.cost_per_booking)
    assert_equal({ "USD" => 1000 }, row.cost_per_traveler)
    assert_equal 1, report.call.rows.count { |candidate| candidate.campaign_id == "123" }
  end

  test "cohorts use mature denominators and do not count copied clients as inquiries" do
    booking
    report = WeeklyReport::Monthly.new(month: Date.new(2026, 10, 1))
    assert_equal({ eligible: 1, booked_inquiries: 1, pending: 0 }, report.cohorts[:horizons][30])
    assert_equal({ eligible: 0, booked_inquiries: 0, pending: 1 }, report.cohorts[:horizons][60])
    assert_equal 1, report.cohorts[:bookings]
    assert_equal @now, report.as_of
  end

  test "tests and spam are excluded consistently but unlinked bookings stay in totals" do
    booking
    booking(id: 52, crm_inquiry_ref: nil)
    @lead.update!(is_test: true)
    report = WeeklyReport::Monthly.new(month: Date.new(2026, 10, 1))
    assert_equal 0, report.totals[:inquiries]
    assert_equal 1, report.totals[:bookings]
    assert_equal 1, report.completeness[:unlinked_bookings]
  end

  test "legacy connected calls without an inquiry remain unknown and copied calls do not double count" do
    client = Client.create!(name: "Synthetic legacy call")
    client.activity_events.create!(kind: "call", summary: "Connected", occurred_at: Time.zone.local(2026, 10, 3), metadata: { "outcome" => "connected" })
    client.activity_events.create!(kind: "call", summary: "Copied", occurred_at: Time.zone.local(2026, 10, 3), metadata: { "outcome" => "connected", "inquiry_id" => @lead.id, "from_lead_event_id" => 999 })
    report = WeeklyReport::Monthly.new(month: Date.new(2026, 10, 1))
    assert_equal 1, report.totals[:connected_calls]
    assert_equal 1, report.completeness[:unlinked_calls]
    assert_equal 1, report.rows.find { |row| row.source == "Unknown (call without inquiry)" }.connected_calls
  end

  test "source-level exact cost includes spend-only campaigns without duplicating campaign totals" do
    booking
    (Date.new(2026, 10, 1)..Date.new(2026, 10, 31)).each do |date|
      %w[123 999].each { |id| DailyAdSpend.record!(spent_on: date, source: "google_ads", campaign_id: id, campaign_name: "Campaign #{id}", currency: "USD", amount_minor: 100) }
    end
    report = WeeklyReport::Monthly.new(month: Date.new(2026, 10, 1), view: "paid")
    source = report.source_rows.find { |row| row.source == "google_ads" }
    assert_equal({ "USD" => 6200 }, source.cost_per_booking)
    assert_equal 1, source.booked
    assert_equal({ "USD" => 3100 }, report.rows.find { |row| row.campaign_id == "123" }.spend)
    assert_equal 2, report.rows.count { |row| row.source == "google_ads" }
    DailyAdSpend.find_by!(spent_on: Date.new(2026, 10, 31), campaign_id: "999").destroy!
    incomplete = WeeklyReport::Monthly.new(month: Date.new(2026, 10, 1), view: "paid")
    assert_nil incomplete.source_rows.find { |row| row.source == "google_ads" }.cost_per_booking
  end

  test "undated historical money is visibly incomplete and archives do not erase received cash" do
    booking
    PerfectBook::Booking.create!(perfectbook_id: 99, perfectbook_contact_id: 99, paid_minor: 50000, synced_at: @now)
    @lead.archive!
    report = WeeklyReport::Monthly.new(month: Date.new(2026, 10, 1))
    assert_equal 1, report.totals[:inquiries]
    assert_equal 1, report.cohorts[:bookings]
    assert_equal 1, report.totals[:bookings]
    assert_equal({ "USD" => 50000 }, report.totals[:net_received])
    assert_equal 1, report.completeness[:undated_paid_bookings]
  end

  test "review preserves mismatches and reopens only for changed upstream evidence" do
    item = booking(trip_name: "Reviewed different trip", start_date: Date.new(2026, 12, 1))
    prior = item.inquiry_binding.attributes
    item.update!(paid_minor: 100_000)
    BookingInquiryBinding.sync!(item)
    assert_nil item.binding_issue
    assert_equal @lead, item.reload.primary_inquiry
    assert_equal prior, item.inquiry_binding.attributes
    item.update!(start_date: Date.new(2027, 1, 1))
    BookingInquiryBinding.sync!(item)
    assert_nil item.reload.primary_inquiry
    BookingInquiryBinding.link!(item, lead: @lead, actor: "captain", evidence: "Reviewed new date", reason: "Date changed")
    BookingInquiryBinding.sync!(item)
    assert_equal @lead, item.reload.primary_inquiry
  end

  test "unvalidated references remain unlinked and cannot export purchases" do
    item = booking(crm_inquiry_ref: nil)
    item.update!(crm_inquiry_ref: @lead.reference)
    BookingInquiryBinding.sync!(item)
    assert_nil item.reload.primary_inquiry
    assert_nil item.inquiry_binding
    assert_match(/Unvalidated/, item.binding_issue)
    assert_nil AdConversions.paid_booking(@lead)
  end

  test "unlinked test clients are excluded from monthly and weekly totals" do
    Client.create!(name: "Synthetic test client", perfectbook_contact_id: 44, is_test: true)
    booking(crm_inquiry_ref: nil)
    booking(id: 52, crm_inquiry_ref: "SH-NONE")
    report = WeeklyReport::Monthly.new(month: Date.new(2026, 10, 1))
    assert_equal 0, report.totals[:bookings]
    assert_empty report.totals[:net_received]
    assert_equal 0, WeeklyReport::Summary.new(week_start: Date.new(2026, 10, 12)).rows.sum(&:booked)
    assert_empty report.lifetime_bookers
  end

  test "current paid month uses common completed-day activity and spend cutoff" do
    travel_to Time.zone.local(2026, 10, 3, 10)
    booking(receipt: Time.zone.local(2026, 10, 2, 9))
    booking(id: 52, receipt: Time.zone.local(2026, 10, 3, 9))
    (Date.new(2026, 10, 1)..Date.new(2026, 10, 2)).each do |date|
      DailyAdSpend.record!(spent_on: date, source: "google_ads", campaign_id: "123", campaign_name: "Test", currency: "USD", amount_minor: 100)
    end
    report = WeeklyReport::Monthly.new(view: "paid")
    assert_equal Date.new(2026, 10, 2), report.end_date
    row = report.rows.find { |entry| entry.booked.positive? }
    assert_equal 1, row.booked
    assert_equal({ "USD" => 200 }, row.cost_per_booking)
    assert_equal 2, WeeklyReport::Monthly.new.totals[:bookings]
  end

  test "lifetime currency repeats and original source remain separate from direct referrals" do
    referrer = Client.create!(name: "Synthetic referrer")
    @lead.update!(referred_by_client: referrer)
    booking
    client = @lead.convert_to_client!
    second = Lead.create!(name: "Repeat", source: "manual", existing_client: client,
      perfectbook_contact_id: 44, received_at: Time.zone.local(2026, 10, 20), source_choice: "search")
    item = booking(id: 52, receipt: Time.zone.local(2026, 10, 25), currency: "EUR")
    BookingInquiryBinding.link!(item, lead: second, actor: "test", evidence: "Repeat", reason: "Different inquiry")
    report = WeeklyReport::Monthly.new(month: Date.new(2026, 10, 1))
    booker = report.lifetime_bookers.sole
    assert_equal @lead, booker[:inquiry]
    assert_equal 0, booker[:currencies]["USD"][:repeat_bookings]
    assert_equal 1, booker[:currencies]["EUR"][:repeat_bookings]
    assert_equal({ "USD" => 900_000, "EUR" => 900_000 }, report.original_source_lifetime.sole[:booked_value])
    assert_equal [ 51 ], report.downstream_referrals.sole[:bookings].map(&:perfectbook_id)
    assert_equal({ "USD" => 50_000 }, report.downstream_referrals.sole[:net_received])
  end

  test "all binding kinds validate every upstream matching field" do
    id = 70
    %w[explicit inferred reviewed].each do |state|
      { crm_inquiry_ref: "SH-OTHER", perfectbook_contact_id: 99, trip_id: 77, trip_name: "Changed trip", departure_id: 88, start_date: Date.new(2027, 1, 1) }.each do |field, value|
        item = booking(id: id, crm_inquiry_ref: nil)
        id += 1
        BookingInquiryBinding.link!(item, lead: @lead, actor: "test", evidence: "Matched", state: state)
        item.update!(paid_minor: 100_000)
        BookingInquiryBinding.sync!(item)
        assert_equal @lead, item.reload.primary_inquiry
        assert_equal state, item.inquiry_binding.state
        before = item[field]
        item.update!(field => value)
        BookingInquiryBinding.sync!(item)
        assert_nil item.reload.primary_inquiry
        assert_match(/evidence changed/, item.binding_issue)
        report = WeeklyReport::Monthly.new(month: Date.new(2026, 10, 1))
        assert_equal 1, report.rows.find { |row| row.source == "Unlinked booking" }.booked
        assert_equal id - 71, report.lifetime_bookers.sum { |booker| booker[:currencies].values.sum { |currency| currency[:bookings] } }
        item.update!(field => before)
        BookingInquiryBinding.sync!(item)
        assert_equal @lead, item.reload.primary_inquiry
        assert_equal state, item.inquiry_binding.state
      end
    end
  end

  test "re-review records changed evidence on the binding independently of audits" do
    item = booking
    fingerprint = item.inquiry_binding.upstream_fingerprint
    item.update!(departure_id: 99)
    BookingInquiryBinding.sync!(item)
    assert_nil item.reload.primary_inquiry
    BookingInquiryBinding.link!(item, lead: @lead, actor: "captain", evidence: "Confirmed changed departure", reason: "Rescheduled")
    assert_not_equal fingerprint, item.reload.inquiry_binding.upstream_fingerprint
    @lead.activity_events.where(kind: "booking_link").delete_all
    BookingInquiryBinding.sync!(item)
    assert_equal @lead, item.reload.primary_inquiry
    assert_equal "reviewed", item.inquiry_binding.state
  end

  test "original lifetime source uses established client testimony and its corrections" do
    client = Current.set(user_email: "captain@example.test") do
      Client.create!(name: "Original client", perfectbook_contact_id: 44, source_choice: "event")
    end
    @lead.update!(existing_client: client)
    booking
    report = -> { WeeklyReport::Monthly.new(month: Date.new(2026, 10, 1)) }
    assert_equal SourceHistory::ANSWERS["event"], report.call.original_source_lifetime.sole[:source]
    Current.set(user_email: "captain@example.test") do
      client.source_correction_reason = "Confirmed original discovery on call"
      client.update!(source_choice: "youtube")
    end
    assert_equal SourceHistory::ANSWERS["youtube"], report.call.original_source_lifetime.sole[:source]
    assert_equal "personal_referral", @lead.reload.reported_source_code
  end

  test "converted client corrections override the copied original lead answer" do
    Current.set(user_email: "captain@example.test") do
      @lead.source_correction_reason = "Confirmed on call"
      @lead.update!(source_choice: "event")
    end
    client = @lead.convert_to_client!
    booking
    Current.set(user_email: "captain@example.test") do
      client.source_correction_reason = "Corrected original discovery"
      client.update!(source_choice: "youtube")
    end
    assert_equal "event", @lead.reload.reported_source_code
    assert_equal SourceHistory::ANSWERS["youtube"], WeeklyReport::Monthly.new(month: Date.new(2026, 10, 1)).original_source_lifetime.sole[:source]
  end

  test "original acquisition without confirmed testimony uses earliest first touch or stays unknown" do
    client = Client.create!(name: "Original client", perfectbook_contact_id: 44)
    @lead.update!(existing_client: client)
    booking
    later = Lead.create!(name: "Later search", source: "manual", existing_client: client, received_at: Time.zone.local(2026, 10, 20),
      metadata: { "acquisition" => { "first_touch" => { "observed_at" => "2026-10-20T16:00:00Z", "source" => "search" } } })
    item = booking(id: 52, receipt: Time.zone.local(2026, 10, 25))
    BookingInquiryBinding.link!(item, lead: later, actor: "test", evidence: "Repeat", reason: "Repeat inquiry")
    report = -> { WeeklyReport::Monthly.new(month: Date.new(2026, 10, 1)) }
    assert_equal "instagram (first observed)", report.call.original_source_lifetime.sole[:source]
    @lead.update!(metadata: {})
    later.update!(metadata: {})
    assert_equal "Unknown original acquisition", report.call.original_source_lifetime.sole[:source]
  end

  test "repeat bookings and distinct new and returning paying bookers remain separate in all views" do
    booking(id: 50, receipt: Time.zone.local(2026, 9, 15))
    booking
    client = @lead.convert_to_client!
    metadata = @lead.metadata.deep_dup
    metadata["acquisition"]["last_non_direct_touch"]["campaign_id"] = "999"
    other = Lead.create!(name: "Second repeat", source: "google_ads", perfectbook_contact_id: 44, existing_client: client,
      received_at: Time.zone.local(2026, 10, 20), metadata: metadata)
    item = booking(id: 52, receipt: Time.zone.local(2026, 10, 25))
    BookingInquiryBinding.link!(item, lead: other, actor: "test", evidence: "Second inquiry", reason: "Repeat booking")
    %w[reported paid first].each do |view|
      report = WeeklyReport::Monthly.new(month: Date.new(2026, 10, 1), view: view)
      assert_equal 2, report.source_rows.sum(&:returning)
      assert_equal [ 44 ], report.source_rows.flat_map(&:returning_booker_ids).uniq
      assert_equal [ 2, 1, 0 ], report.totals.values_at(:repeat_bookings, :returning_bookers, :new_bookers)
    end
  end

  test "a new monthly booker remains new when buying a second booking" do
    booking
    booking(id: 52, receipt: Time.zone.local(2026, 10, 25))
    report = WeeklyReport::Monthly.new(month: Date.new(2026, 10, 1))
    assert_equal [ 1, 0, 1 ], report.totals.values_at(:repeat_bookings, :returning_bookers, :new_bookers)
  end

  test "credentials without owner terms confirmation stay off" do
    settings = Setting.current
    settings.update!(meta_dataset_id: "123456789012345", meta_access_token: "synthetic-token", google_feed_password: "synthetic-password", meta_terms_accepted: false, google_terms_accepted: false)
    assert_not settings.meta_configured?
    assert_not settings.google_feed_configured?
  end

  test "date-only receipts stay in cohorts lifetime and repeat ordering without timestamps" do
    first = booking(first_received_at: nil, first_received_precision: "date")
    booking(id: 52, receipt: Time.zone.local(2026, 10, 16, 9))
    report = WeeklyReport::Monthly.new(month: Date.new(2026, 10, 1))
    assert_equal 2, report.totals[:bookings]
    assert_equal 2, report.cohorts[:bookings]
    assert_equal 1, report.cohorts[:horizons][30][:booked_inquiries]
    assert_equal 1_800_000, report.lifetime_bookers.sole[:currencies]["USD"][:booked_value]
    assert_equal 1, report.lifetime_bookers.sole[:currencies]["USD"][:repeat_bookings]
    assert_equal({ "USD" => 100_000 }, report.lifetime_bookers.sole[:net_received])
    assert_nil first.reload.first_received_at
    assert_equal Date.new(2026, 10, 15), first.receipt_date
  end

  test "source-free inferred inquiries remain missing in every report view" do
    @lead.update!(source: "manual", metadata: {}, source_choice: "not_asked", source_correction_reason: "No verified source")
    item = booking(crm_inquiry_ref: nil)
    BookingInquiryBinding.link!(item, lead: @lead, actor: "test", evidence: "Contact trip time", state: "inferred")
    %w[reported paid first].each do |view|
      report = WeeklyReport::Monthly.new(month: Date.new(2026, 10, 1), view: view)
      row = report.rows.find { |entry| entry.booked == 1 }
      assert_equal(view == "reported" ? "Not asked yet" : "Unknown (legacy_missing)", row.source)
      assert_equal 1, report.cohorts[:bookings]
      assert_equal "Unknown original acquisition", report.lifetime_bookers.sole[:source]
      assert_equal "Unknown original acquisition", report.original_source_lifetime.sole[:source]
    end
  end

end
