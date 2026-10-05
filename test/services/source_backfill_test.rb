require "test_helper"
require "tmpdir"

class SourceBackfillTest < ActiveSupport::TestCase
  test "dry run is deterministic and reviewed import reconciles without testimony or ad events" do
    lead = Lead.create!(name: "Synthetic legacy", source: "google_ads", campaign_name: "Legacy", perfectbook_contact_id: 44,
      trip_interest: "Test trip", received_at: 2.months.ago, metadata: { "attribution" => { "gclid" => "test-only" } })
    PerfectBook::Booking.create!(perfectbook_id: 55, perfectbook_contact_id: 44, trip_name: "Test trip",
      first_received_at: 1.month.ago, total_minor: 900_000, receipts_minor: 50_000, net_received_minor: 50_000, currency: "USD", synced_at: Time.current)
    before = SourceBackfill.inventory
    original = lead.metadata.deep_dup
    Dir.mktmpdir do |directory|
      SourceBackfill.dry_run!(directory)
      assert_equal before, SourceBackfill.inventory
      assert_equal original, lead.reload.metadata
      path = File.join(directory, "batch-0001.csv")
      digest = Digest::SHA256.file(path).hexdigest
      # A normal mirror refresh is transport noise, not changed review evidence.
      PerfectBook::Booking.find_by!(perfectbook_id: 55).update_columns(synced_at: 1.minute.from_now, updated_at: 1.minute.from_now)
      repeated = File.join(directory, "repeat")
      SourceBackfill.dry_run!(repeated)
      assert_equal File.binread(path), File.binread(File.join(repeated, "batch-0001.csv"))
      result = SourceBackfill.apply!(path, reviewer: "test-reviewer", approved_digest: digest)
      assert result["count_money_reconciled"]
      assert_equal before["money"], SourceBackfill.inventory["money"]
      assert_equal "not_asked", lead.reload.source_answer_state
      assert_equal original["attribution"], lead.metadata["attribution"]
      assert lead.metadata["legacy_observed"]["not_self_reported"]
      assert_equal "inferred", BookingInquiryBinding.find_by!(perfectbook_id: 55).state
      assert_equal 0, AdConversion.count
      assert_equal 1, SourceBackfillBatch.count
      assert_equal result, SourceBackfill.apply!(path, reviewer: "test-reviewer", approved_digest: digest)
      assert_equal 1, SourceBackfillBatch.count
      assert_equal 1, lead.activity_events.where(kind: "source_backfill").count
    end
  end

  test "audit activity clocks do not stale later inferences across reviewed batches" do
    start = Time.zone.local(2026, 10, 4, 10)
    travel_to start
    lead = Lead.create!(name: "Synthetic legacy", source: "manual", perfectbook_contact_id: 44,
      trip_interest: "Test trip", received_at: 2.months.ago)
    [55, 56].each do |id|
      PerfectBook::Booking.create!(perfectbook_id: id, perfectbook_contact_id: 44, trip_name: "Test trip",
        first_received_at: 1.month.ago, synced_at: Time.current)
    end
    original = SourceBackfill.fingerprint(lead)
    rows = SourceBackfill.proposals
    Dir.mktmpdir do |directory|
      rows.each_with_index do |row, index|
        travel_to start + (index + 1).hours
        path = File.join(directory, "batch-#{index}.csv")
        File.write(path, CSV.generate { |out| out << SourceBackfill::HEADERS; out << row })
        result = SourceBackfill.apply!(path, reviewer: "test", approved_digest: Digest::SHA256.file(path).hexdigest)
        assert result["count_money_reconciled"]
        assert_equal original, SourceBackfill.fingerprint(lead.reload)
      end
    end
    assert_equal 2, BookingInquiryBinding.where(lead: lead, state: "inferred").count
    assert_equal start + 3.hours, lead.reload.last_activity_at
    lead.update!(trip_interest: "Changed trip")
    assert_not_equal original, SourceBackfill.fingerprint(lead.reload)
  end

  test "inventory includes metadata duplicate and candidate aggregates without customer details" do
    lead = Lead.create!(name: "Synthetic inquiry", email: "shared@example.test", source: "manual",
      perfectbook_contact_id: 44, trip_interest: "Test trip", received_at: 2.months.ago, metadata: { "custom_key" => "private value" })
    client = Client.create!(name: "Synthetic client", email: "shared@example.test")
    Person.create!(name: "Synthetic person", email: "shared@example.test", client: client)
    PerfectBook::Contact.create!(perfectbook_id: 44, name: "Synthetic contact", email: "shared@example.test", synced_at: Time.current)
    item = PerfectBook::Booking.create!(perfectbook_id: 55, perfectbook_contact_id: 44, trip_name: "Test trip",
      first_received_at: 1.month.ago, synced_at: Time.current)
    BookingInquiryBinding.link!(item, lead: lead, actor: "test", evidence: "Reviewed")
    PerfectBook::Booking.create!(perfectbook_id: 56, perfectbook_contact_id: 99, synced_at: Time.current)
    inventory = SourceBackfill.inventory
    assert_equal 1, inventory["metadata_keys"]["custom_key"]
    assert_equal 1, inventory["cross_record_email_groups_for_review"]
    assert_equal({ "zero" => 1, "one" => 1, "multiple" => 0 }, inventory["booking_candidate_counts"])
    assert_not_includes JSON.generate(inventory), "shared@example.test"
    assert_not_includes JSON.generate(inventory), "private value"
  end

  test "snapshot-only application never matches unrelated booking candidates" do
    lead = Lead.create!(name: "Snapshot", source: "manual")
    PerfectBook::Booking.create!(perfectbook_id: 80, perfectbook_contact_id: 80,
      first_received_at: 1.day.ago, trip_name: "Unrelated trip", synced_at: Time.current)
    row = [ "legacy_snapshot", lead.id, nil, SourceBackfill.fingerprint(lead), "Existing fields" ]
    Dir.mktmpdir do |directory|
      path = File.join(directory, "snapshot.csv")
      File.write(path, CSV.generate { |out| out << SourceBackfill::HEADERS; out << row })
      SourceBackfill.stub(:candidates_for, ->(*) { raise "Unrelated candidate scan" }) do
        result = SourceBackfill.apply!(path, reviewer: "test", approved_digest: Digest::SHA256.file(path).hexdigest)
        assert result["count_money_reconciled"]
        assert_equal 1, result["after"]["bookings"]
        assert_equal result["before"], result["after"]
        assert_not result["after"].key?("booking_candidate_counts")
      end
    end
    assert lead.reload.metadata["legacy_observed"]
  end

  test "binding application matches only the affected booking" do
    lead = Lead.create!(name: "Matched", source: "manual", perfectbook_contact_id: 90,
      received_at: 2.days.ago, trip_interest: "Matched trip")
    booking = PerfectBook::Booking.create!(perfectbook_id: 90, perfectbook_contact_id: 90,
      first_received_at: 1.day.ago, trip_name: "Matched trip", synced_at: Time.current)
    PerfectBook::Booking.create!(perfectbook_id: 91, perfectbook_contact_id: 91,
      first_received_at: 1.day.ago, trip_name: "Unrelated trip", synced_at: Time.current)
    row = [ "infer_binding", booking.id, lead.id, SourceBackfill.fingerprint(booking), SourceBackfill.fingerprint(lead) ]
    match = SourceBackfill.method(:candidates_for)
    queried = []
    Dir.mktmpdir do |directory|
      path = File.join(directory, "binding.csv")
      File.write(path, CSV.generate { |out| out << SourceBackfill::HEADERS; out << row })
      SourceBackfill.stub(:candidates_for, ->(candidate) { queried << candidate.perfectbook_id; match.call(candidate) }) do
        result = SourceBackfill.apply!(path, reviewer: "test", approved_digest: Digest::SHA256.file(path).hexdigest)
        assert result["count_money_reconciled"]
      end
    end
    assert_equal [ 90 ], queried
    assert_equal lead, booking.reload.primary_inquiry
    assert_equal "inferred", booking.inquiry_binding.state
    assert booking.inquiry_binding.upstream_fingerprint.present?
    assert_not BookingInquiryBinding.exists?(perfectbook_id: 91)
  end

  test "stale evidence and wrong approvals rollback whole batches" do
    first = Lead.create!(name: "Synthetic first", source: "manual")
    second = Lead.create!(name: "Synthetic second", source: "manual")
    Dir.mktmpdir do |directory|
      SourceBackfill.dry_run!(directory)
      path = File.join(directory, "batch-0001.csv")
      assert_raises(ArgumentError) { SourceBackfill.apply!(path, reviewer: "test", approved_digest: "wrong") }
      second.update!(source: "referral")
      digest = Digest::SHA256.file(path).hexdigest
      assert_raises(ArgumentError) { SourceBackfill.apply!(path, reviewer: "test", approved_digest: digest) }
      assert_nil first.reload.metadata&.dig("legacy_observed")
      assert_equal 0, SourceBackfillBatch.count
    end
  end

  test "multiple contact trip candidates never become newest-lead credit" do
    first = Lead.create!(name: "Synthetic first", source: "manual", perfectbook_contact_id: 44, trip_interest: "Test trip", received_at: 2.months.ago)
    client = first.convert_to_client!
    Lead.create!(name: "Synthetic repeat", source: "manual", existing_client: client, trip_interest: "Test trip", received_at: 2.months.ago)
    PerfectBook::Booking.create!(perfectbook_id: 55, perfectbook_contact_id: 44, trip_name: "Test trip", first_received_at: 1.month.ago, synced_at: Time.current)
    rows = SourceBackfill.proposals
    assert_equal "unresolved", rows.last.first
    assert_match(/2 defensible/, rows.last.last)
  end
end
