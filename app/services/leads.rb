# frozen_string_literal: true

# Shared rules for the website-form intake endpoints (see
# docs/leads-intake.md): relay HMAC
# verification, source derivation, suspicion scoring, and rate limiting.
module Leads
  PAID_MEDIUMS = %w[cpc ppc paid paid_social paidsocial].freeze
  META_SOURCES = %w[facebook instagram meta fb ig].freeze
  DISPOSABLE_DOMAINS = %w[
    mailinator.com guerrillamail.com 10minutemail.com tempmail.com
    yopmail.com trashmail.com getnada.com mohmal.com
  ].freeze
  URL_PATTERN = %r{https?://|www\.}i.freeze
  FAST_SUBMIT_SECONDS = 3
  AUTO_ARCHIVE_HITS = %i[honeypot too_fast].freeze
  DUPLICATE_WINDOW = 24.hours

  SPAM_HIT_LABELS = {
    "honeypot" => "Hidden field filled",
    "too_fast" => "Submitted under 3s",
    "many_links" => "Too many links",
    "disposable_domain" => "Disposable email domain",
    "name_matches_email" => "Name matches email"
  }.freeze

  module_function

  # Verifies X-Sherpa-Signature "t=<unix>,v1=<hex>" over "t.raw_body".
  # Returns the caller name (key id when the signer sends one, else
  # "relay"), or nil when the signature is missing or invalid.
  def verify_relay_signature(raw_body, header, secret:, now: Time.current)
    return nil if header.blank? || secret.blank?

    pairs = header.to_s.split(",").map { |pair| pair.strip.split("=", 2) }
    return nil unless pairs.all? { |key, value| key.present? && value.present? }

    parts = pairs.to_h
    timestamp = parts["t"].to_i
    return nil if timestamp.zero? || (now.to_i - timestamp).abs > 300

    expected = OpenSSL::HMAC.hexdigest("SHA256", secret, "#{timestamp}.#{raw_body}")
    return nil unless Rack::Utils.secure_compare(expected, parts["v1"].to_s)

    parts["kid"].presence || "relay"
  end

  def sign_relay_body(raw_body, secret, timestamp: Time.current.to_i)
    digest = OpenSSL::HMAC.hexdigest("SHA256", secret, "#{timestamp}.#{raw_body}")
    "t=#{timestamp},v1=#{digest}"
  end

  # google_ads on a click id or google+paid; meta_ads on a meta
  # source with a paid medium or ad_id; trade_show on utm_medium=event (booth QR codes);
  # else website_form.
  def derive_source(attribution)
    attribution = (attribution || {}).with_indifferent_access
    return "google_ads" if attribution[:gclid].present? ||
      attribution[:gbraid].present? || attribution[:wbraid].present?

    source = attribution[:utm_source].to_s.strip.downcase
    medium = attribution[:utm_medium].to_s.strip.downcase
    paid = PAID_MEDIUMS.include?(medium)
    return "google_ads" if source == "google" && paid
    return "meta_ads" if META_SOURCES.include?(source) && (paid || attribution[:ad_id].present?)
    return "trade_show" if medium == "event"

    "website_form"
  end

  # Never a rejection: returns [ score 0..100, symbols of hit reasons ].
  # A filled hidden field (:honeypot) or a submit under 3s (:too_fast)
  # routes the lead straight to Archived as spam; other hits only flag it.
  def suspicion_hits(name:, email:, message:, seconds_to_submit:, honeypot: nil)
    hits = []
    hits << :honeypot if honeypot.to_s.present?
    hits << :too_fast if seconds_to_submit && seconds_to_submit < FAST_SUBMIT_SECONDS
    hits << :many_links if message.to_s.scan(URL_PATTERN).size > 2
    local = email.to_s.split("@").first.to_s.downcase
    hits << :name_matches_email if local.present? &&
      name.to_s.strip.downcase.delete(" ") == local.delete("._-")
    hits << :disposable_domain if DISPOSABLE_DOMAINS.include?(email.to_s.split("@").last.to_s.downcase)
    [ [ hits.size * 25, 100 ].min, hits ]
  end

  def auto_archive?(hits)
    Array(hits).any? { |hit| AUTO_ARCHIVE_HITS.include?(hit.to_sym) }
  end

  def spam_reason(hits)
    Array(hits).map(&:to_s).reject(&:blank?).map { |hit| SPAM_HIT_LABELS.fetch(hit, hit.humanize) }.join(", ").presence
  end

  def honeypot_catches_count(range = nil)
    scope = ::Lead.where(
      "json_valid(leads.metadata) AND EXISTS (SELECT 1 FROM json_each(json_extract(leads.metadata, '$.suspicion_hits')) WHERE json_each.value = 'honeypot')"
    )
    scope = scope.where("COALESCE(received_at, leads.created_at) BETWEEN ? AND ?", range.first, range.last) if range
    scope.count
  end

  def find_by_merged_submission_id(submission_id)
    return nil if submission_id.blank?

    ::Lead.where(
      "json_valid(leads.metadata) AND EXISTS (SELECT 1 FROM json_each(json_extract(leads.metadata, '$.merged_submission_ids')) WHERE json_each.value = ?)",
      submission_id
    ).first
  end

  def find_recent_duplicate(email:, message:, trip_handle: nil, trip_title: nil, auto_archived: false, exclude_external_ref: nil, now: Time.current)
    normalized_email = email.to_s.strip.downcase
    return nil if normalized_email.blank?

    cutoff = now - DUPLICATE_WINDOW
    candidates = ::Lead.where("lower(email) = ?", normalized_email)
      .where("COALESCE(received_at, created_at) >= ?", cutoff)
    candidates = candidates.where.not(external_ref: exclude_external_ref) if exclude_external_ref.present?
    candidates = candidates.order(Arel.sql("COALESCE(received_at, created_at) DESC, id DESC"))

    candidates.find do |lead|
      next false if lead.converted?
      next false if (lead.archived? || lead.spam_marked_at.present?) && !auto_archived
      next false unless same_or_compatible_trip?(lead, trip_handle: trip_handle, trip_title: trip_title, message: message)

      normalize_message_for_duplicate(lead.message) == normalize_message_for_duplicate(message)
    end
  end

  def same_or_compatible_trip?(lead, trip_handle:, trip_title:, message:)
    existing_handle = lead.trip_handle.to_s.strip.downcase.presence
    incoming_handle = trip_handle.to_s.strip.downcase.presence
    return existing_handle == incoming_handle if existing_handle && incoming_handle

    existing_title = (lead.trip_title.presence || lead.trip_interest.presence).to_s.strip.downcase.presence
    incoming_title = trip_title.to_s.strip.downcase.presence
    return existing_title == incoming_title if existing_title && incoming_title

    existing_any = existing_handle || existing_title
    incoming_any = incoming_handle || incoming_title
    if normalize_message_for_duplicate(message).blank? && normalize_message_for_duplicate(lead.message).blank?
      return existing_any == incoming_any
    end

    true
  end

  def normalize_message_for_duplicate(text)
    text.to_s.downcase.gsub(/[^[:alnum:]\s]/, " ").squish
  end

  def merge_duplicate!(lead, submission_id:, fields:, caller_name:, now: Time.current)
    lead.with_lock do
      meta = (lead.metadata || {}).deep_dup
      merged_ids = Array(meta["merged_submission_ids"])
      unless merged_ids.include?(submission_id)
        merged_ids << submission_id
        meta["merged_submission_ids"] = merged_ids
        lead.metadata = meta
        lead.phone = fields[:phone] if lead.phone.blank? && fields[:phone].present?
        lead.phone_raw = fields[:phone_raw] if lead.phone_raw.blank? && fields[:phone_raw].present?
        lead.save! if lead.changed?

        summary = if fields[:message].present?
          "Duplicate website inquiry merged: #{fields[:message].truncate(240)}"
        else
          "Duplicate website inquiry merged (no message)."
        end
        lead.activity_events.create!(
          kind: "duplicate_inquiry",
          summary: summary,
          occurred_at: now,
          metadata: {
            "submission_id" => submission_id,
            "message" => fields[:message],
            "trip_handle" => fields[:trip_handle],
            "trip_title" => fields[:trip_title],
            "placement" => fields[:placement],
            "caller" => caller_name
          }.compact
        )
      end
    end
    lead
  end

  def rate_limit_exceeded?(key, limit:, window:, now: Time.current)
    LeadRateLimitEntry.transaction do
      LeadRateLimitEntry.where("expires_at <= ?", now).delete_all
      entries = LeadRateLimitEntry.where(key: key)
      if entries.count >= limit
        entries.minimum(:expires_at).to_i - now.to_i + 1
      else
        entries.create!(expires_at: now + window)
        nil
      end
    end
  end
end
