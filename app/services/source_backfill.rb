require "csv"
require "digest"

# Reviewed, small, deterministic batches. No matching by email/name, no inferred
# testimony, no merges/deletes, and no historical ad outcomes.
module SourceBackfill
  BATCH_SIZE = 100
  HEADERS = %w[action record_id inquiry_id fingerprint evidence].freeze
  module_function

  def inventory
    { "leads" => Lead.count, "clients" => Client.count, "people" => Person.count,
      "lead_sources" => Lead.group(:source).count, "answer_states" => Lead.group(:source_answer_state).count,
      "placements" => Lead.group(:placement).count.transform_keys { |key| key || "(missing)" },
      "channels" => Lead.group(:capture_channel).count.transform_keys { |key| key || "(missing)" },
      "spam" => Tagging.joins(:tag).where(taggable_type: "Lead", tags: { name: Lead::SUSPECTED_SPAM_TAG }).count,
      "legacy_attribution" => Lead.where("json_type(metadata, '$.attribution') = 'object'").count,
      "acquisition_snapshots" => Lead.where("json_type(metadata, '$.acquisition') = 'object'").count,
      "shared_email_groups_for_review" => Lead.where.not(email: [ nil, "" ]).group(:email).having("COUNT(*) > 1").count.size,
      "converted" => Lead.where.not(converted_client_id: nil).count, "tests" => Lead.where(is_test: true).count,
      "lead_kinds" => Lead.group(:kind).count, "client_kinds" => Client.group(:kind).count,
      "perfectbook_contacts" => PerfectBook::Contact.count, "perfectbook_contact_kinds" => PerfectBook::Contact.group(:kind).count,
      "shared_client_email_groups_for_review" => Client.where.not(email: [ nil, "" ]).group(:email).having("COUNT(*) > 1").count.size,
      "referrals" => Lead.where.not(referral_code: [ nil, "" ]).count,
      "bookings" => PerfectBook::Booking.count, "bindings" => BookingInquiryBinding.count,
      "money" => {
        "booked_value" => PerfectBook::Booking.group(:currency).sum(:total_minor),
        "legacy_paid" => PerfectBook::Booking.group(:currency).sum(:paid_minor),
        # The agreed scalar cash totals are USD-ledger facts, not invoice currency.
        "cash_minor" => { "USD" => %w[receipts_minor refunds_minor net_received_minor].to_h { |field| [ field, PerfectBook::Booking.sum(field) ] } }
      },
      "missing_money" => PerfectBook::Booking.where(net_received_minor: nil).count,
      "unlinked" => PerfectBook::Booking.where.not(perfectbook_id: BookingInquiryBinding.select(:perfectbook_id)).count }
  end

  def fingerprint(record)
    fields = if record.is_a?(Lead)
      record.attributes.except("updated_at", "metadata")
        .merge("metadata" => (record.metadata || {}).except("legacy_observed"), "suspected_spam" => record.suspected_spam?)
    else
      record.attributes.except("synced_at", "updated_at")
    end
    Digest::SHA256.hexdigest(JSON.generate(fields))
  end

  def proposals
    rows = []
    Lead.includes(:tags).order(:id).find_each do |lead|
      next if lead.metadata&.key?("legacy_observed")
      rows << [ "legacy_snapshot", lead.id, nil, fingerprint(lead), "Existing source/campaign only; not self-report or original first touch" ]
    end
    PerfectBook::Booking.includes(:inquiry_binding).order(:id).find_each do |booking|
      next if booking.inquiry_binding || booking.crm_inquiry_ref.present?
      candidates = candidates_for(booking)
      if candidates.size == 1
        rows << [ "infer_binding", booking.id, candidates.first.id, fingerprint(booking), fingerprint(candidates.first) ]
      else
        rows << [ "unresolved", booking.id, nil, fingerprint(booking), "#{candidates.size} defensible contact/trip/time candidates" ]
      end
    end
    rows
  end

  def candidates_for(booking)
    cutoff = booking.first_received_at
    return [] if cutoff.nil? || booking.trip_name.blank?
    client_ids = Client.where(perfectbook_contact_id: booking.perfectbook_contact_id).select(:id)
    Lead.where(perfectbook_contact_id: booking.perfectbook_contact_id)
      .or(Lead.where(converted_client_id: client_ids)).or(Lead.where(existing_client_id: client_ids))
      .where(is_test: false).where("COALESCE(received_at, leads.created_at) <= ?", cutoff)
      .to_a.reject(&:suspected_spam?).select do |lead|
        [ lead.trip_title, lead.trip_interest ].compact.include?(booking.trip_name) &&
          (!lead.travel_month || (booking.start_date && lead.travel_month == booking.start_date.month)) &&
          (!lead.travel_year || (booking.start_date && lead.travel_year == booking.start_date.year))
      end
  end

  def dry_run!(directory)
    FileUtils.mkdir_p(directory)
    File.write(File.join(directory, "inventory.json"), JSON.pretty_generate(inventory))
    proposals.each_slice(BATCH_SIZE).with_index(1) do |rows, number|
      csv = CSV.generate { |out| out << HEADERS; rows.each { |row| out << row } }
      path = File.join(directory, format("batch-%04d.csv", number))
      raise ArgumentError, "Dry-run output already exists: #{path}" if File.exist?(path)
      File.write(path, csv)
    end
  end

  def apply!(path, reviewer:, approved_digest:)
    raise ArgumentError, "Reviewer required" if reviewer.blank?
    raw = File.read(path)
    digest = Digest::SHA256.hexdigest(raw)
    raise ArgumentError, "Reviewed SHA256 does not match batch" unless digest == approved_digest
    prior = SourceBackfillBatch.find_by(digest: digest)
    return prior.reconciliation_json if prior
    rows = CSV.parse(raw, headers: true)
    raise ArgumentError, "Invalid batch" unless rows.headers == HEADERS && rows.size.between?(1, BATCH_SIZE)
    SourceBackfillBatch.transaction do
      before = inventory
      rows.each do |row|
        case row["action"]
        when "legacy_snapshot"
          lead = Lead.find(row["record_id"])
          raise ArgumentError, "Stale lead #{lead.id}; regenerate dry run" unless fingerprint(lead) == row["fingerprint"]
          metadata = (lead.metadata || {}).deep_dup
          raise ArgumentError, "Snapshot already exists" if metadata.key?("legacy_observed")
          snapshot = { "source" => lead.source, "campaign" => lead.campaign_name,
            "provenance" => "reviewed legacy fields", "unknown_reason" => "legacy_missing",
            "not_self_reported" => true, "not_original_first_touch" => true }
          metadata["legacy_observed"] = snapshot
          lead.update_columns(metadata: metadata)
          lead.activity_events.create!(kind: "source_backfill", summary: "Legacy observed source preserved",
            occurred_at: Time.current, metadata: { "batch" => digest, "reviewer" => reviewer,
              "added_key" => "legacy_observed", "prior_value" => nil, "new_value" => snapshot })
        when "infer_binding"
          booking = PerfectBook::Booking.find(row["record_id"])
          lead = Lead.find(row["inquiry_id"])
          raise ArgumentError, "Stale booking/inquiry; regenerate dry run" unless fingerprint(booking) == row["fingerprint"] && fingerprint(lead) == row["evidence"]
          raise ArgumentError, "Candidate evidence changed" unless candidates_for(booking).map(&:id) == [ lead.id ]
          raise ArgumentError, "Booking already linked" if booking.inquiry_binding || booking.crm_inquiry_ref.present?
          BookingInquiryBinding.link!(booking, lead: lead, actor: reviewer, evidence: "Reviewed batch #{digest}: contact/trip/time", state: "inferred")
        when "unresolved"
          # Review-only. Unknown stays unknown.
        else
          raise ArgumentError, "Invalid action"
        end
      end
      after = inventory
      stable = %w[leads clients people bookings money answer_states lead_sources converted tests referrals missing_money]
      raise "Count/money reconciliation failed" unless before.slice(*stable) == after.slice(*stable)
      result = { "before" => before, "after" => after, "count_money_reconciled" => true, "rows" => rows.size }
      SourceBackfillBatch.create!(digest: digest, reviewer: reviewer, reconciliation_json: result)
      result
    end
  end
end
