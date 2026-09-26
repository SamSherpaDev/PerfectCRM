# frozen_string_literal: true

require "digest"

# Lead outcomes reported back to Google Ads and Meta so the ad platforms
# learn which clicks become real inquiries and bookings (README.md,
# "Ad conversions"). Rules:
#
# - Consent-safe: only leads that arrived with a click ID (gclid, gbraid,
#   wbraid, or fbclid) are reported. The storefront form strips click IDs
#   when marketing consent is off, so a click ID means consent was on.
# - Never reported: archived leads, suspected spam, and leads lost as
#   "not a fit" (the negative signal by omission).
# - One AdConversion row per lead per event; rows are never re-created, so
#   a status moving back and forth never reports twice.
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
  # Fixed signal values in cents; a booking reports its margin instead
  # (Setting#ad_booking_value_percent of the booking total).
  VALUES_MINOR = { "lead" => 300_00, "qualified" => 1_000_00, "quote" => 2_000_00 }.freeze
  QUALIFIED_BANDS = %w[strong possible].freeze
  QUALIFIED_STATUSES = %w[chatting quoted].freeze
  # Leads older than this are no longer scanned: Google rejects gclid
  # imports more than 90 days after the click.
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
    first_seen = Time.zone.parse(attribution(lead)["first_seen_at"].to_s) rescue nil
    first_seen || lead.received_at || lead.created_at
  end

  def excluded?(lead)
    lead.archived? || lead.suspected_spam? || (lead.status == "lost" && lead.lost_reason == "not_a_fit") ||
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
    detect(lead, now).filter_map do |event, facts|
      next if existing.include?(event)

      AdConversion.create!(
        lead: lead, event: event, event_id: event_id(lead, event),
        occurred_at: facts[:occurred_at], value_minor: facts[:value_minor],
        google: google && event != "lead", meta_status: "pending"
      )
    rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid
      nil
    end
  end

  # { event => { occurred_at:, value_minor: } } for each event reached.
  def detect(lead, now)
    floor = click_at(lead)
    clamp = ->(time) { [ [ time || now, floor ].max, now ].min }
    events = { "lead" => { occurred_at: clamp.(lead.received_at || lead.created_at), value_minor: VALUES_MINOR["lead"] } }

    history = lead.activity_events.where(kind: %w[stage_change automation]).order(:occurred_at, :id).to_a
    if QUALIFIED_BANDS.include?(lead.fit_band) && (at = qualified_at(history))
      events["qualified"] = { occurred_at: clamp.(at), value_minor: VALUES_MINOR["qualified"] }
    end

    quote_times = history.filter_map do |event|
      event.occurred_at if event.kind == "stage_change" && event.metadata["to"] == "quoted"
    end
    quote_times << lead.stage_changed_at if lead.status == "quoted"
    quote_times << Quote.where(lead_id: lead.id).where.not(sent_at: nil).minimum(:sent_at)
    if quote_times.compact.any?
      events["quote"] = { occurred_at: clamp.(quote_times.compact.min), value_minor: VALUES_MINOR["quote"] }
    end

    if (booking = paid_booking(lead))
      events["booked"] = { occurred_at: clamp.(booking.first_paid_at), value_minor: booking_value_minor(booking) }
    end
    events
  end

  def qualified_at(history)
    owner_at = nil
    band = nil
    history.each do |event|
      data = event.metadata
      if event.kind == "stage_change" && QUALIFIED_STATUSES.include?(data["to"]) &&
          data["actor"].present? && data["actor"] != "automation"
        owner_at ||= event.occurred_at
      elsif event.kind == "automation"
        band = data["fit_band"]
      end
      return event.occurred_at if owner_at && QUALIFIED_BANDS.include?(band)
    end
    nil
  end

  # The first payment observed on an active booking after the inquiry.
  def paid_booking(lead)
    contact_ids = [ lead.perfectbook_contact_id, lead.converted_client&.perfectbook_contact_id ].compact.uniq
    return nil if contact_ids.empty?

    PerfectBook::Booking.where(perfectbook_contact_id: contact_ids)
      .where("paid_minor > 0")
      .where("status IS NULL OR status NOT IN (?)", TemplateContext::INACTIVE_BOOKING_STATUSES)
      .where("first_paid_at >= ?", lead.received_at || lead.created_at)
      .order(:first_paid_at, :id).first
  end

  def booking_value_minor(booking, settings: Setting.current)
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
  # intake job and the nightly sweep never send the same row twice.
  # Returns :sent, :failed, :skipped, or nil when nothing happened.
  def deliver_meta!(row, settings: Setting.current, now: Time.current)
    return nil unless meta_due?(row, now)

    claim = AdConversion.where(id: row.id, meta_status: row.meta_status,
      meta_attempts: row.meta_attempts, updated_at: row.updated_at)
    lead = row.lead
    skip_reason = if excluded?(lead)
      "Archived, spam, not a fit, or business test"
    elsif row.occurred_at < now - META_WINDOW
      "Older than Meta's 7-day limit"
    end
    if skip_reason
      changed = claim.update_all(meta_status: "skipped", meta_error: skip_reason, updated_at: now)
      row.reload
      return changed.positive? ? :skipped : nil
    end
    return nil unless settings.meta_configured?

    if row.meta_attempts >= META_MAX_ATTEMPTS
      changed = claim.update_all(meta_status: "failed", meta_error: "Delivery interrupted; attempt limit reached", updated_at: now)
      row.reload
      return changed.positive? ? :failed : nil
    end

    attempt = row.meta_attempts + 1
    return nil if claim.update_all(meta_status: "sending", meta_attempts: attempt, updated_at: now).zero?

    delivery = AdConversion.where(id: row.id, meta_status: "sending", meta_attempts: attempt)
    begin
      MetaClient.new(settings).deliver(row)
      changed = delivery.update_all(meta_status: "sent", meta_sent_at: now, meta_error: nil, updated_at: now)
      changed.positive? ? :sent : nil
    rescue MetaClient::Error => error
      changed = delivery.update_all(meta_status: "failed", meta_error: error.message.truncate(300), updated_at: now)
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
    when "sending" then row.updated_at <= now - META_CLAIM_TIMEOUT
    when "failed"
      row.meta_attempts < META_MAX_ATTEMPTS && row.updated_at <= now - (row.meta_attempts**2).hours
    else false
    end
  end
end
