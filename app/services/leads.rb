# frozen_string_literal: true

# Shared rules for the website-form intake endpoints (see
# docs/leads-intake.md, mirroring intake-spec.md section 2): relay HMAC
# verification, source derivation, suspicion scoring, and rate limiting.
module Leads
  PAID_MEDIUMS = %w[cpc ppc paid].freeze
  META_SOURCES = %w[facebook instagram meta].freeze
  DISPOSABLE_DOMAINS = %w[
    mailinator.com guerrillamail.com 10minutemail.com tempmail.com
    yopmail.com trashmail.com getnada.com mohmal.com
  ].freeze
  URL_PATTERN = %r{https?://|www\.}i.freeze

  module_function

  # Verifies X-Sherpa-Signature "t=<unix>,v1=<hex>" over "t.raw_body".
  # Returns the caller name (key id when the signer sends one, else
  # "relay"), or nil when the signature is missing or invalid.
  def verify_relay_signature(raw_body, header, secret:, now: Time.current)
    return nil if header.blank? || secret.blank?

    parts = header.to_s.split(",").map(&:strip).to_h { |pair| pair.split("=", 2) }
    timestamp = parts["t"].to_i
    return nil if timestamp.zero? || (now.to_i - timestamp).abs > 300

    expected = OpenSSL::HMAC.hexdigest("SHA256", secret, "#{timestamp}.#{raw_body}")
    return nil unless Rack::Utils.secure_compare(expected, parts["v1"].to_s)

    parts["kid"].presence || parts["k"].presence || "relay"
  end

  def sign_relay_body(raw_body, secret, timestamp: Time.current.to_i)
    digest = OpenSSL::HMAC.hexdigest("SHA256", secret, "#{timestamp}.#{raw_body}")
    "t=#{timestamp},v1=#{digest}"
  end

  # google_ads on a click id or google+paid; meta_ads on a meta
  # source+paid medium; else website_form.
  def derive_source(attribution)
    attribution = (attribution || {}).with_indifferent_access
    return "google_ads" if attribution[:gclid].present? ||
      attribution[:gbraid].present? || attribution[:wbraid].present?

    source = attribution[:utm_source].to_s.strip.downcase
    medium = attribution[:utm_medium].to_s.strip.downcase
    paid = PAID_MEDIUMS.include?(medium)
    return "google_ads" if source == "google" && paid
    return "meta_ads" if META_SOURCES.include?(source) && paid

    "website_form"
  end

  # Never a rejection: returns [ score 0..100, symbols of hit reasons ].
  def suspicion_hits(name:, email:, message:, seconds_to_submit:)
    hits = []
    hits << :too_fast if seconds_to_submit && seconds_to_submit < 3
    hits << :many_links if message.to_s.scan(URL_PATTERN).size > 2
    local = email.to_s.split("@").first.to_s.downcase
    hits << :name_matches_email if local.present? &&
      name.to_s.strip.downcase.delete(" ") == local.delete("._-")
    hits << :disposable_domain if DISPOSABLE_DOMAINS.include?(email.to_s.split("@").last.to_s.downcase)
    [ [ hits.size * 25, 100 ].min, hits ]
  end

  # Sliding window on the cache store. Returns nil when allowed, or the
  # seconds until the oldest entry expires when over the limit.
  def rate_limit_exceeded?(key, limit:, window:, now: Time.current)
    store = Rails.cache
    entries = Array(store.read(key)).map(&:to_i)
    cutoff = now.to_i - window
    entries = entries.select { |time| time > cutoff }
    if entries.size >= limit
      return entries.min + window - now.to_i + 1
    end

    store.write(key, entries + [ now.to_i ], expires_in: window)
    nil
  end
end
