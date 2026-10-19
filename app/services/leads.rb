# frozen_string_literal: true

# Shared rules for the website-form intake endpoints (see
# docs/leads-intake.md): relay HMAC
# verification, source derivation, suspicion scoring, and rate limiting.
module Leads
  PAID_MEDIUMS = %w[cpc ppc paid].freeze
  META_SOURCES = %w[facebook instagram meta].freeze
  DISPOSABLE_DOMAINS = %w[
    mailinator.com guerrillamail.com 10minutemail.com tempmail.com
    yopmail.com trashmail.com getnada.com mohmal.com
  ].freeze
  URL_PATTERN = %r{https?://|www\.}i.freeze
  FAST_SUBMIT_SECONDS = 3
  HIGH_CONFIDENCE_SPAM_THRESHOLD = 50
  DUPLICATE_WINDOW = 24.hours
  NEAR_IDENTICAL_SIMILARITY = 0.85
  HONEYPOT_CACHE_KEY = "intake:honeypot:dropped"

  SPAM_HIT_WEIGHTS = {
    too_fast: 50,
    missing_timing: 50,
    many_links: 25,
    disposable_domain: 25,
    name_matches_email: 25
  }.freeze

  SPAM_HIT_LABELS = {
    "too_fast" => "Submitted under 3s",
    "missing_timing" => "Missing or invalid timing",
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
  # source+paid medium; trade_show on utm_medium=event (booth QR codes);
  # else website_form.
  def derive_source(attribution)
    attribution = (attribution || {}).with_indifferent_access
    return "google_ads" if attribution[:gclid].present? ||
      attribution[:gbraid].present? || attribution[:wbraid].present?

    source = attribution[:utm_source].to_s.strip.downcase
    medium = attribution[:utm_medium].to_s.strip.downcase
    paid = PAID_MEDIUMS.include?(medium)
    return "google_ads" if source == "google" && paid
    return "meta_ads" if META_SOURCES.include?(source) && paid
    return "trade_show" if medium == "event"

    "website_form"
  end

  # Never a rejection: returns [ score 0..100, symbols of hit reasons ].
  # Strong bot signals (:too_fast under 3s, :missing_timing when timing is
  # missing or unparseable) carry 50 points; moderate signals carry 25 points.
  # Scores >= 50 are high-confidence spam (routed straight to Archived and
  # marked spam); scores 25..49 stay in New with the suspected_spam tag.
  def suspicion_hits(name:, email:, message:, seconds_to_submit:)
    hits = []
    if seconds_to_submit.nil?
      hits << :missing_timing
    elsif seconds_to_submit < FAST_SUBMIT_SECONDS
      hits << :too_fast
    end
    hits << :many_links if message.to_s.scan(URL_PATTERN).size > 2
    local = email.to_s.split("@").first.to_s.downcase
    hits << :name_matches_email if local.present? &&
      name.to_s.strip.downcase.delete(" ") == local.delete("._-")
    hits << :disposable_domain if DISPOSABLE_DOMAINS.include?(email.to_s.split("@").last.to_s.downcase)
    score = hits.sum { |hit| SPAM_HIT_WEIGHTS.fetch(hit, 25) }
    [ [ score, 100 ].min, hits ]
  end

  def high_confidence_spam?(score)
    score.to_i >= HIGH_CONFIDENCE_SPAM_THRESHOLD
  end

  def spam_reason(hits)
    Array(hits).map(&:to_s).reject(&:blank?).map { |hit| SPAM_HIT_LABELS.fetch(hit, hit.humanize) }.join(", ").presence
  end

  def record_honeypot_drop!(now: Time.current)
    Rails.cache.increment(HONEYPOT_CACHE_KEY, 1, expires_in: 30.days)
    ActivityEvent.create!(
      subject: Setting.current,
      kind: "honeypot_drop",
      summary: "Honeypot trap dropped a bot submission",
      occurred_at: now,
      metadata: {}
    )
  end

  def honeypot_drops_count(range = nil)
    scope = ActivityEvent.where(kind: "honeypot_drop")
    return scope.where(occurred_at: range).count if range

    [ Rails.cache.read(HONEYPOT_CACHE_KEY).to_i, scope.where(occurred_at: 30.days.ago..Time.current).count ].max
  end

  def find_by_merged_submission_id(submission_id)
    return nil if submission_id.blank?

    ::Lead.where(
      "json_valid(leads.metadata) AND EXISTS (SELECT 1 FROM json_each(json_extract(leads.metadata, '$.merged_submission_ids')) WHERE json_each.value = ?)",
      submission_id
    ).first
  end

  def find_recent_duplicate(email:, message:, trip_handle: nil, trip_title: nil, suspected_spam: false, exclude_external_ref: nil, now: Time.current)
    normalized_email = email.to_s.strip.downcase
    return nil if normalized_email.blank?

    cutoff = now - DUPLICATE_WINDOW
    candidates = ::Lead.where("lower(email) = ?", normalized_email)
      .where("COALESCE(received_at, created_at) >= ?", cutoff)
    candidates = candidates.where.not(external_ref: exclude_external_ref) if exclude_external_ref.present?
    candidates = candidates.order(Arel.sql("COALESCE(received_at, created_at) DESC, id DESC"))

    candidates.find do |lead|
      next false if (lead.archived? || lead.spam_marked_at.present?) && !suspected_spam
      next false unless same_or_compatible_trip?(lead, trip_handle: trip_handle, trip_title: trip_title, message: message)

      near_identical_message?(lead.message, message)
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

  def near_identical_message?(first, second)
    norm_a = normalize_message_for_duplicate(first)
    norm_b = normalize_message_for_duplicate(second)
    return true if norm_a == norm_b
    return false if norm_a.blank? || norm_b.blank?

    max_len = [ norm_a.length, norm_b.length ].max
    distance = DidYouMean::Levenshtein.distance(norm_a, norm_b)
    return true if (1.0 - (distance.to_f / max_len)) >= NEAR_IDENTICAL_SIMILARITY

    words_a = norm_a.split
    words_b = norm_b.split
    if words_a.size >= 4 && words_b.size >= 4
      union = (words_a | words_b).size
      intersection = (words_a & words_b).size
      return true if union.positive? && (intersection.to_f / union) >= NEAR_IDENTICAL_SIMILARITY
    end

    false
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
