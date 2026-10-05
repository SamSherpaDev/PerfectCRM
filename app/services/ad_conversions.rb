# frozen_string_literal: true

require "digest"

# Lead outcomes reported back to Google Ads and Meta so the ad platforms
# learn which clicks become real inquiries and bookings (README.md,
# "Ad conversions" owns eligibility, values, and delivery behavior).
module AdConversions
  GOOGLE_CLICK_KEYS = %w[gclid gbraid wbraid].freeze
  GOOGLE_CONVERSION_NAMES = {
    "qualified" => "Qualified inquiry",
    "quote" => "Quote sent",
    "booked" => "Booking (deposit paid)"
  }.freeze
  META_EVENT_NAMES = {
    "lead" => "Lead",
    "qualified" => "QualifiedLead",
    "quote" => "Quote",
    "booked" => "Purchase"
  }.freeze
  # Fixed signal values in cents; booking valuation lives in booking_value_minor.
  VALUES_MINOR = { "lead" => 300_00, "qualified" => 1_000_00, "quote" => 2_000_00 }.freeze
  QUALIFIED_BANDS = %w[strong possible].freeze
  QUALIFIED_STATUSES = %w[chatting quoted].freeze
  # Scan recent inquiries and older inquiries with recent bound receipts;
  # delivery applies each platform's click/event window independently.
  LOOKBACK = 90.days
  GCLID_WINDOW = 90.days
  # Enhanced conversions for leads (hashed email or phone, no gclid).
  ENHANCED_WINDOW = 63.days
  # Meta rejects events older than seven days.
  META_WINDOW = 7.days
  META_MAX_ATTEMPTS = 5
  META_CLAIM_TIMEOUT = 5.minutes
  TIME_ZONE = "America/Los_Angeles"

  module_function

  def enabled?(settings = Setting.current)
    settings.meta_configured? || settings.google_feed_configured?
  end

  def attribution(lead)
    acquisition = lead.metadata.is_a?(Hash) ? lead.metadata["acquisition"] : nil
    touch = acquisition&.dig("last_non_direct_touch") || acquisition&.dig("last_touch")
    return touch if touch.is_a?(Hash)
    data = lead.metadata.is_a?(Hash) ? lead.metadata["attribution"] : nil
    data.is_a?(Hash) ? data : {}
  end

  def google_click_ids(lead)
    attribution(lead).slice(*GOOGLE_CLICK_KEYS).transform_values { |value| value.to_s.strip }.compact_blank
  end

  # The storefront keeps fbclid in the landing URL; a relay may send it bare.
  def fbclid(lead)
    data = attribution(lead)
    direct = data["fbclid"].to_s.strip
    return direct if direct.present?

    query = URI.parse(data["landing_url"].to_s).query
    query.present? ? Rack::Utils.parse_query(query)["fbclid"].to_s.strip.presence : nil
  rescue URI::InvalidURIError
    nil
  end

  def click_id?(lead)
    google_click_ids(lead).any? || fbclid(lead).present?
  end

  def click_at(lead)
    data = attribution(lead)
    Time.iso8601((data["observed_at"] || data["first_seen_at"]).to_s)
  rescue ArgumentError
    nil
  end

  def measurement_permitted?(lead)
    permission = lead.metadata&.dig("acquisition", "permission")
    permission.is_a?(Hash) && permission["state"] == "allowed" && permission["measurement"] == true &&
      permission["sharing"] == true && permission["opted_out"] != true
  end

  def excluded?(lead)
    lead.is_test? || lead.converted_client&.is_test? || lead.existing_client&.is_test? || !measurement_permitted?(lead) || lead.archived? || lead.suspected_spam? || (lead.status == "lost" && lead.lost_reason == "not_a_fit") ||
      [ "info@sherpaholidays.com", Mail.mailbox_address ].include?(contact_email(lead)) ||
      User.allowed_email?(contact_email(lead))
  end

  def reportable?(lead)
    click_id?(lead) && !excluded?(lead)
  end

  # Creates the rows for every event the lead has reached and not yet
  # recorded. Returns the new rows.
  def record!(lead, now: Time.current)
    return [] unless reportable?(lead)

    existing = lead.ad_conversions.pluck(:event)
    google = google_click_ids(lead).any?
    outcomes = detect(lead, now).map { |event, facts| [ event, facts ] }
    paid_bookings(lead).each do |booking|
      outcomes << [ "booked", { occurred_at: booking.first_received_at, value_minor: booking_value_minor(booking), perfectbook_id: booking.perfectbook_id } ]
    end
    outcomes.filter_map do |event, facts|
      next if event != "booked" && existing.include?(event)
      next if facts[:occurred_at].nil? || facts[:occurred_at] > now

      attributes = {
        lead: lead, event: event, event_id: event == "booked" ? "sh-booking-#{facts[:perfectbook_id]}-purchase" : event_id(lead, event),
        perfectbook_id: facts[:perfectbook_id], occurred_at: facts[:occurred_at], value_minor: facts[:value_minor],
        google: google && event != "lead", meta_status: "pending"
      }
      if event == "booked"
        booking = PerfectBook::Booking.find_by!(perfectbook_id: facts[:perfectbook_id])
        booking.with_lock do
          next unless paid_bookings(lead).exists?(perfectbook_id: booking.perfectbook_id)
          AdConversion.create!(**attributes)
        end
      else
        AdConversion.create!(**attributes)
      end
    rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid
      nil
    end
  end

  # { event => { occurred_at:, value_minor: } } for each event reached.
  def detect(lead, now)
    events = { "lead" => { occurred_at: lead.received_at || lead.created_at, value_minor: VALUES_MINOR["lead"] } }

    history = lead.activity_events.where(kind: "stage_change").order(:occurred_at, :id).to_a
    if QUALIFIED_BANDS.include?(lead.fit_band) && (at = qualified_at(history))
      events["qualified"] = { occurred_at: at, value_minor: VALUES_MINOR["qualified"] }
    end

    quote_times = history.filter_map do |event|
      event.occurred_at if event.kind == "stage_change" && event.metadata["to"] == "quoted"
    end
    quote_times << lead.stage_changed_at if lead.status == "quoted"
    quote_times << Quote.where(lead_id: lead.id).where.not(sent_at: nil).minimum(:sent_at)
    if quote_times.compact.any?
      events["quote"] = { occurred_at: quote_times.compact.min, value_minor: VALUES_MINOR["quote"] }
    end

    events
  end

  def qualified_at(history)
    history.find do |event|
      data = event.metadata
      QUALIFIED_STATUSES.include?(data["to"]) &&
        data["actor"].present? && data["actor"] != "automation"
    end&.occurred_at
  end

  # Only explicit/reviewed bindings with actual timestamp evidence can export.
  # Inferred backfill links and date-only manual receipts never become fake events.
  def paid_bookings(lead)
    PerfectBook::Booking.joins(:inquiry_binding)
      .where(booking_inquiry_bindings: { lead_id: lead.id, state: %w[explicit reviewed] })
      .where(binding_issue: nil, unavailable_at: nil, cancelled_at: nil, first_received_precision: "timestamp")
      .where.not(first_received_at: nil)
      .where("receipts_minor > 0")
      .where("status IS NULL OR status NOT IN (?)", TemplateContext::INACTIVE_BOOKING_STATUSES)
      .where("first_received_at >= ?", lead.received_at || lead.created_at)
      .order(:first_received_at, :id)
  end

  def paid_booking(lead) = paid_bookings(lead).first

  def legacy_purchase_conflict?(lead, booking)
    contacts = [ lead.perfectbook_contact_id, lead.converted_client&.perfectbook_contact_id, lead.existing_client&.perfectbook_contact_id ].compact
    clients = Client.where(perfectbook_contact_id: contacts).select(:id)
    inquiries = Lead.where(id: lead.id).or(Lead.where(perfectbook_contact_id: contacts))
      .or(Lead.where(converted_client_id: clients)).or(Lead.where(existing_client_id: clients)).select(:id)
    AdConversion.where(event: "booked", perfectbook_id: nil, lead_id: inquiries)
      .where("created_at >= ?", booking.first_received_at)
      .where("(meta_attempts > 0 AND meta_status != 'rejected') OR google_serve_count > 0 OR meta_sent_at IS NOT NULL OR google_first_served_at IS NOT NULL").exists?
  end

  def correct_booking_owner!(booking, lead:)
    row = AdConversion.find_by(event: "booked", perfectbook_id: booking.perfectbook_id)
    return unless row
    row.with_lock do
      next if row.lead_id == lead.id
      if row.possibly_delivered?
        row.update!(google_skip_reason: "Booking inquiry corrected after export; review platform history",
          meta_error: "Booking inquiry corrected after export; review platform history")
      else
        row.update!(lead: lead, google: google_click_ids(lead).any?, meta_status: "pending", meta_attempts: 0,
          meta_error: nil, google_skip_reason: nil)
      end
    end
  end

  def booking_skip_reason(row)
    return nil unless row.event == "booked"
    return "Booking link or authoritative receipt evidence missing; review required" if row.perfectbook_id.nil? || !paid_bookings(row.lead).exists?(perfectbook_id: row.perfectbook_id)
    return "Legacy Purchase may already have exported this booking; review platform history" if legacy_purchase_conflict?(row.lead, row.booking)
    nil
  end

  def invalid_booking_outcome?(row) = booking_skip_reason(row).present?

  def booking_value_minor(booking, settings: Setting.current)
    return VALUES_MINOR["quote"] unless booking.currency == "USD"

    total = booking.total_minor.presence || booking.paid_minor.to_i
    (total * settings.ad_booking_value_percent / 100.0).round
  end

  # The Lead event reuses the form's submission_id so a browser pixel Lead
  # with the same eventID deduplicates against it.
  def event_id(lead, event)
    submission = lead.external_ref.to_s.delete_prefix("website_form:") if lead.external_ref.to_s.start_with?("website_form:")
    return submission if event == "lead" && submission.present?

    "sh-lead-#{lead.id}-#{event}"
  end

  def contact_email(lead)
    lead.display_email.to_s.strip.downcase.presence
  end

  def contact_phone(lead)
    phone = lead.phone.to_s.gsub(/[^\d+]/, "")
    phone.match?(/\A\+\d{7,15}\z/) ? phone : nil
  end

  def sha256(value)
    Digest::SHA256.hexdigest(value)
  end

  # Google's normalization: lowercase, and dots dropped from Gmail names.
  def google_email_hash(email)
    return nil if email.blank?

    local, domain = email.downcase.split("@", 2)
    local = local.delete(".") if %w[gmail.com googlemail.com].include?(domain)
    sha256("#{local}@#{domain}")
  end

  def google_phone_hash(phone)
    phone.present? ? sha256(phone) : nil
  end

  def meta_email_hash(email)
    email.present? ? sha256(email.downcase) : nil
  end

  # Meta wants digits only, country code included.
  def meta_phone_hash(phone)
    phone.present? ? sha256(phone.delete("+")) : nil
  end

  # Sends one row to Meta when it is due. Claims the row first, so the
  # intake job and the nightly sweep cannot share an active delivery claim.
  # Returns :sent, :failed, :skipped, or nil when nothing happened.
  def deliver_meta!(row, settings: Setting.current, now: Time.current)
    row.reload
    if row.meta_status == "sending" && row.updated_at <= now - META_CLAIM_TIMEOUT
      changed = AdConversion.where(id: row.id, meta_status: "sending", updated_at: row.updated_at)
        .update_all(meta_status: "uncertain", meta_error: "Delivery result unknown; review platform history", updated_at: now)
      row.reload
      return changed.positive? ? :failed : nil
    end
    return nil unless meta_due?(row, now)

    claim = AdConversion.where(id: row.id, lead_id: row.lead_id, meta_status: row.meta_status,
      meta_attempts: row.meta_attempts, updated_at: row.updated_at)
    lead = row.lead.reload
    skip_reason = if excluded?(lead)
      "No measurement permission, archived, spam, not a fit, or test"
    elsif (reason = booking_skip_reason(row))
      reason
    elsif row.occurred_at > now
      "Event time is in the future"
    elsif click_at(lead) && click_at(lead) > row.occurred_at
      "Event precedes observed click; review required"
    elsif row.occurred_at < now - META_WINDOW
      "Older than Meta's 7-day limit"
    end
    if skip_reason
      changed = claim.update_all(meta_status: "skipped", meta_error: skip_reason, updated_at: now)
      row.reload
      return changed.positive? ? :skipped : nil
    end
    return nil unless settings.meta_configured?

    attempt = row.meta_attempts + 1
    return nil if claim.update_all(meta_status: "sending", meta_attempts: attempt, updated_at: now).zero?

    delivery = AdConversion.where(id: row.id, meta_status: %w[sending uncertain], meta_attempts: attempt)
    begin
      MetaClient.new(settings).deliver(row)
      changed = delivery.update_all(meta_status: "sent", meta_sent_at: now, meta_error: nil, updated_at: now)
      changed.positive? ? :sent : nil
    rescue MetaClient::Error => error
      status = error.is_a?(MetaClient::Rejected) ? "rejected" : "uncertain"
      message = status == "uncertain" ? "#{error.message}; delivery result unknown; review platform history" : error.message
      changed = delivery.update_all(meta_status: status, meta_error: message.truncate(300), updated_at: now)
      if changed.positive?
        Rails.logger.warn("[ad conversions] meta #{row.event} for lead #{row.lead_id} failed: #{error.message.truncate(200)}")
        :failed
      end
    ensure
      row.reload
    end
  end

  # Pending rows go out now; failed rows retry with a growing wait
  # (1, 4, 9, 16 hours) until META_MAX_ATTEMPTS.
  def meta_due?(row, now)
    case row.meta_status
    when "pending" then true
    when "rejected"
      row.meta_attempts < META_MAX_ATTEMPTS && row.updated_at <= now - (row.meta_attempts**2).hours
    else false
    end
  end
end
