# frozen_string_literal: true

# Shared rules for the website-form intake endpoints (see
# docs/leads-intake.md): relay HMAC
# verification, source derivation, suspicion scoring, and rate limiting.
module Leads
  PAID_MEDIUMS = %w[cpc ppc paid].freeze
  META_PAID_MEDIUMS = (PAID_MEDIUMS + %w[paid_social paidsocial]).freeze
  META_SOURCES = %w[facebook instagram meta fb ig meta_ads].freeze
  TIMING_WINDOWS = {
    "within_3_months" => "Within the next 3 months",
    "next_3_months" => "Within the next 3 months",
    "3_to_6_months" => "In 3 to 6 months",
    "6_to_12_months" => "In 6 to 12 months",
    "12_plus_months" => "More than a year out",
    "spring" => "Spring",
    "summer" => "Summer",
    "autumn" => "Autumn",
    "winter" => "Winter",
    "not_sure" => "Not sure yet"
  }.freeze
  PARTY_SIZE_BANDS = {
    "1" => "Just me (1 traveler)",
    "2" => "2 travelers",
    "3_4" => "3 to 4 travelers",
    "5_8" => "5 to 8 travelers",
    "9_plus" => "9 or more travelers",
    "not_sure" => "Not sure yet"
  }.freeze
  TRIP_INTENTS = {
    "cultural_tour" => "Private cultural and sightseeing tour (hotel-based)",
    "trek" => "Private Himalayan trek (lodge-to-lodge)",
    "mixed_tour_walks" => "Sightseeing, wildlife and short walks",
    "helicopter_lodge" => "Everest by air or helicopter-supported lodge trip",
    "expedition_climb" => "High-altitude expedition or peak climb",
    "multi_country" => "Nepal combined with Bhutan, Tibet or India",
    "ready_to_plan" => "Ready to plan dates and get a written proposal",
    "comparing_options" => "Comparing routes and seasons for an upcoming trip",
    "need_guidance" => "Looking for guidance on what fits our group",
    "early_research" => "Early research for a future trip",
    "everest_trek" => "Everest Base Camp or Khumbu trek",
    "annapurna_trek" => "Annapurna or Pokhara trek",
    "cultural_wildlife" => "Cultural, Kathmandu, Pokhara, and Chitwan tour",
    "custom_private" => "Custom private itinerary",
    "comfort_walking" => "Easy walking and mountain views",
    "not_sure" => "Not sure yet, help me choose"
  }.freeze
  DISPOSABLE_DOMAINS = %w[
    mailinator.com guerrillamail.com 10minutemail.com tempmail.com
    yopmail.com trashmail.com getnada.com mohmal.com
  ].freeze
  URL_PATTERN = %r{(?:https?://)?www\.|https?://}i.freeze
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
  # source with a paid medium or ad/campaign id; trade_show on utm_medium=event (booth QR codes);
  # else website_form.
  def derive_source(attribution)
    attribution = (attribution || {}).with_indifferent_access
    return "google_ads" if attribution[:gclid].present? ||
      attribution[:gbraid].present? || attribution[:wbraid].present?

    source = attribution[:utm_source].to_s.strip.downcase
    medium = attribution[:utm_medium].to_s.strip.downcase
    paid = PAID_MEDIUMS.include?(medium)
    meta_ad_evidence = META_PAID_MEDIUMS.include?(medium) ||
      attribution[:ad_id].present? || attribution[:campaign_id].present? || attribution[:adset_id].present?
    return "google_ads" if source == "google" && paid
    return "meta_ads" if META_SOURCES.include?(source) && meta_ad_evidence
    return "meta_ads" if source.blank? && attribution[:fbclid].present? && meta_ad_evidence
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

  # An itinerary designer or trip quiz submission merges only into one with
  # the same built trip or quiz answers; a changed trip or answer set is a
  # new inquiry with its own email.
  def find_recent_duplicate(email:, message:, trip_handle: nil, trip_title: nil, auto_archived: false, exclude_external_ref: nil, itinerary: nil, quiz: nil, phone: nil, now: Time.current)
    normalized_email = email.to_s.strip.downcase
    return nil if normalized_email.blank?

    cutoff = now - DUPLICATE_WINDOW
    candidates = ::Lead.where("lower(email) = ?", normalized_email)
      .where("COALESCE(received_at, created_at) >= ?", cutoff)
    candidates = candidates.where.not(external_ref: exclude_external_ref) if exclude_external_ref.present?
    candidates = candidates.order(Arel.sql("COALESCE(received_at, created_at) DESC, id DESC"))

    candidates.find do |lead|
      next false if quiz && phone.present? && lead.phone.present? && lead.phone != phone
      next false if lead.converted?
      next false if (lead.archived? || lead.spam_marked_at.present?) && !auto_archived
      next false if itinerary && Leads::Itinerary.signature(lead.itinerary) != Leads::Itinerary.signature(itinerary)
      next false if (quiz || lead.quiz) && Leads::TripQuiz.signature(lead.quiz) != Leads::TripQuiz.signature(quiz)
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
        lead.name = fields[:name] if lead.name.blank? && fields[:name].present?
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

  def extract_inquiry_dropdowns(payload)
    updates = {}
    trip_meta = {}
    party_meta = {}
    errors = {}

    trip = payload["trip"].is_a?(Hash) ? payload["trip"] : {}
    party = payload["party"].is_a?(Hash) ? payload["party"] : {}
    qual = payload["qualification"].is_a?(Hash) ? payload["qualification"] : {}
    if payload.key?("qualification") && !payload["qualification"].is_a?(Hash) && !payload["qualification"].nil?
      errors["qualification"] = "invalid"
    end

    timing_key = if trip.key?("timing_window")
      "trip.timing_window"
    elsif trip.key?("travel_timing")
      "trip.travel_timing"
    elsif qual.key?("timing_window")
      "qualification.timing_window"
    elsif qual.key?("travel_timing")
      "qualification.travel_timing"
    end
    if timing_key
      raw_timing = if trip.key?("timing_window")
        trip["timing_window"]
      elsif trip.key?("travel_timing")
        trip["travel_timing"]
      elsif qual.key?("timing_window")
        qual["timing_window"]
      else
        qual["travel_timing"]
      end
      if raw_timing.nil? || raw_timing == ""
        trip_meta["timing_window"] = nil
        trip_meta["timing_label"] = nil
      elsif raw_timing.is_a?(String) && TIMING_WINDOWS.key?(raw_timing.strip)
        window = raw_timing.strip
        raw_label = trip["timing_label"].presence || qual["timing_label"].presence || qual["travel_timing_label"].presence
        if raw_label && (!raw_label.is_a?(String) || raw_label.strip.length > 120)
          errors["trip.timing_label"] = "invalid"
        else
          trip_meta["timing_window"] = window
          trip_meta["timing_label"] = raw_label ? raw_label.strip : TIMING_WINDOWS[window]
          if !trip.key?("timing_unknown") && !trip.key?("month") && !trip.key?("year")
            updates["timing_unknown"] = (window == "not_sure")
          end
        end
      else
        errors[timing_key] = "invalid"
      end
    end

    intent_key = if trip.key?("intent")
      "trip.intent"
    elsif trip.key?("trip_intent")
      "trip.trip_intent"
    elsif qual.key?("intent")
      "qualification.intent"
    elsif qual.key?("trip_intent")
      "qualification.trip_intent"
    end
    if intent_key
      raw_intent = if trip.key?("intent")
        trip["intent"]
      elsif trip.key?("trip_intent")
        trip["trip_intent"]
      elsif qual.key?("intent")
        qual["intent"]
      else
        qual["trip_intent"]
      end
      if raw_intent.nil? || raw_intent == ""
        trip_meta["intent"] = nil
        trip_meta["intent_label"] = nil
      elsif raw_intent.is_a?(String) && TRIP_INTENTS.key?(raw_intent.strip)
        intent = raw_intent.strip
        raw_label = trip["intent_label"].presence || qual["intent_label"].presence || qual["trip_intent_label"].presence
        if raw_label && (!raw_label.is_a?(String) || raw_label.strip.length > 120)
          errors["trip.intent_label"] = "invalid"
        else
          trip_meta["intent"] = intent
          trip_meta["intent_label"] = raw_label ? raw_label.strip : TRIP_INTENTS[intent]
        end
      else
        errors[intent_key] = "invalid"
      end
    end

    band_key = if party.key?("size_band")
      "party.size_band"
    elsif qual.key?("party_size_band")
      "qualification.party_size_band"
    elsif qual.key?("size_band")
      "qualification.size_band"
    elsif qual.key?("party_size")
      "qualification.party_size"
    end
    if band_key
      raw_band = if party.key?("size_band")
        party["size_band"]
      elsif qual.key?("party_size_band")
        qual["party_size_band"]
      elsif qual.key?("size_band")
        qual["size_band"]
      else
        qual["party_size"]
      end
      if raw_band.nil? || raw_band == ""
        party_meta["size_band"] = nil
        party_meta["size_label"] = nil
      elsif raw_band.is_a?(String) && PARTY_SIZE_BANDS.key?(raw_band.strip)
        band = raw_band.strip
        raw_label = party["size_label"].presence || qual["party_size_label"].presence
        if raw_label && (!raw_label.is_a?(String) || raw_label.strip.length > 120)
          errors["party.size_label"] = "invalid"
        else
          party_meta["size_band"] = band
          party_meta["size_label"] = raw_label ? raw_label.strip : PARTY_SIZE_BANDS[band]
          unless party.key?("size")
            updates["party_size"] = band.in?(%w[1 2]) ? band.to_i : nil
          end
        end
      else
        errors[band_key] = "invalid"
      end
    end

    [ updates, trip_meta, party_meta, errors ]
  end
end
