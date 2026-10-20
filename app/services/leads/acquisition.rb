require "uri"
require "time"

# Bounded snapshots, not raw browser payloads. URLs never retain arbitrary query
# values; referrers retain only their host. Consent is independent of contact.
module Leads::Acquisition
  TOUCHES = %w[first_touch last_touch last_non_direct_touch].freeze
  CLICK_KEYS = %w[gclid gbraid wbraid fbclid].freeze
  CAMPAIGN_KEYS = %w[utm_source utm_medium utm_campaign utm_content utm_term campaign_id ad_id adset_id].freeze
  REASONS = %w[legacy_missing not_asked declined_permission no_detectable_referrer unresolved_identity unavailable withdrawn consent_granted_late].freeze
  PERMISSION_STATES = %w[allowed denied unavailable withdrawn].freeze
  module_function

  def parse(payload)
    return nil unless payload.key?("acquisition")
    input = payload["acquisition"]
    raise ArgumentError, "acquisition" unless input.is_a?(Hash)
    permission = input["permission"]
    raise ArgumentError, "acquisition.permission" unless permission.is_a?(Hash) && PERMISSION_STATES.include?(permission["state"])
    %w[measurement sharing opted_out].each do |key|
      raise ArgumentError, "acquisition.permission.#{key}" if permission.key?(key) && ![ true, false ].include?(permission[key])
    end
    allowed = permission["state"] == "allowed" && permission["opted_out"] != true
    result = { "version" => 1, "classifier_version" => "crm-source-v1",
      "permission" => permission.slice("state", "measurement", "sharing", "opted_out").merge("recorded_at" => Time.current.iso8601) }
    result["permission"]["observed_at"] = timestamp(permission["observed_at"]) if permission["observed_at"].present?
    TOUCHES.each do |key|
      # The storefront sends null for a touch it has never observed, such as
      # last_non_direct_touch on a direct visit. Treat it like an omitted touch.
      next if input[key].nil?
      result[key] = touch(input[key], allowed: allowed)
    end
    if allowed && input.key?("submission_page")
      page = input["submission_page"]
      raise ArgumentError, "acquisition.submission_page" unless page.is_a?(Hash)
      result["submission_page"] = { "landing_url" => safe_url(page["url"], campaign: allowed), "referrer_host" => host(page["referrer"]) }
    end
    result
  end

  def touch(input, allowed:)
    raise ArgumentError, "acquisition.touch" unless input.is_a?(Hash)
    return { "unknown_reason" => "declined_permission" } unless allowed
    reason = input["unknown_reason"]
    raise ArgumentError, "acquisition.unknown_reason" if reason.present? && !REASONS.include?(reason)
    result = {}
    result["observed_at"] = timestamp(input["observed_at"]) if input["observed_at"].present?
    (CAMPAIGN_KEYS + CLICK_KEYS).each do |key|
      next if input[key].blank?
      raise ArgumentError, "acquisition.#{key}" unless input[key].is_a?(String) && input[key].length <= 200
      result[key] = input[key].strip
    end
    result["landing_url"] = safe_url(input["landing_url"], campaign: true)
    result["referrer_host"] = host(input["referrer"])
    result["unknown_reason"] = reason if reason.present?
    result["source"] = classify(result)
    result["unknown_reason"] ||= "unavailable" if result["observed_at"].nil?
    result["source"] = "unknown" if result["unknown_reason"].present? && result["unknown_reason"] != "consent_granted_late"
    result
  end

  def eligible?(touch)
    touch.is_a?(Hash) && touch["observed_at"].present? &&
      (touch["unknown_reason"].blank? || touch["unknown_reason"] == "consent_granted_late")
  end

  def permitted?(acquisition)
    acquisition.dig("permission", "state") == "allowed" && acquisition.dig("permission", "opted_out") != true
  end

  def classify(touch)
    compatibility = Leads.derive_source(touch)
    return compatibility unless compatibility == "website_form"
    source = touch["utm_source"].to_s.downcase
    return source if %w[google facebook instagram youtube tiktok pinterest].include?(source)
    return "facebook" if touch["fbclid"].present?
    return "email" if touch["utm_medium"].to_s.downcase == "email"
    referrer = touch["referrer_host"].to_s
    return "search" if referrer.match?(/(?:\A|\.)(google\.com|bing\.com|duckduckgo\.com)\z/)
    return "referral" if referrer.present? && !referrer.match?(/(?:\A|\.)sherpaholidays\.com\z/)
    # No timestamp means missing collection, not a direct session.
    touch["observed_at"].present? ? "direct" : "unknown"
  end

  def timestamp(value)
    time = Time.iso8601(value.to_s)
    raise ArgumentError, "acquisition.observed_at" if time > Time.current + 5.minutes || time < 10.years.ago
    time.utc.iso8601
  rescue ArgumentError
    raise ArgumentError, "acquisition.observed_at"
  end

  def host(value)
    return nil if value.blank?
    uri = URI.parse(value.to_s.include?("://") ? value.to_s : "https://#{value}")
    uri.host.to_s.downcase.first(253).presence if %w[http https].include?(uri.scheme)
  rescue URI::InvalidURIError
    nil
  end

  def safe_url(value, campaign: false)
    return nil if value.blank?
    uri = URI.parse(value.to_s)
    return nil unless %w[http https].include?(uri.scheme) && uri.host.present?
    query = campaign ? URI.decode_www_form(uri.query.to_s).select { |key, val| CAMPAIGN_KEYS.include?(key) && val.length <= 200 } : []
    # Host/path only, no credentials, fragments, click IDs, or arbitrary params.
    path = uri.path.to_s.first(512)
    "#{uri.scheme}://#{uri.host.downcase}#{path}" + (query.any? ? "?#{URI.encode_www_form(query)}" : "")
  rescue URI::InvalidURIError, ArgumentError
    nil
  end

  def legacy_attribution(input, acquisition: nil)
    result = input.slice(*(CAMPAIGN_KEYS + CLICK_KEYS + %w[first_seen_at referral_code]))
      .transform_values { |value| value.to_s.first(200) }
    if input["landing_url"].present?
      begin
        query = URI.decode_www_form(URI.parse(input["landing_url"].to_s).query.to_s).to_h
        result["fbclid"] ||= query["fbclid"].to_s.first(200).presence
      rescue URI::InvalidURIError, ArgumentError
        nil
      end
      result["landing_url"] = safe_url(input["landing_url"], campaign: true)
    end
    if acquisition
      touch = %w[last_non_direct_touch last_touch].map { |key| acquisition[key] }.find { |snapshot| eligible?(snapshot) } ||
        submission_page_fallback(acquisition) || {}
      result = touch.slice(*(CAMPAIGN_KEYS + CLICK_KEYS + %w[landing_url])).merge("first_seen_at" => touch["observed_at"], "referral_code" => result["referral_code"])
      unless permitted?(acquisition)
        result.except!(*(CAMPAIGN_KEYS + CLICK_KEYS + %w[landing_url]))
      end
    end
    result.compact
  end

  def submission_page_fallback(acquisition)
    return nil unless acquisition.is_a?(Hash) && permitted?(acquisition)
    return nil if %w[last_non_direct_touch last_touch].any? { |key| eligible?(acquisition[key]) }

    last_touch = acquisition["last_touch"]
    return nil if last_touch.is_a?(Hash) &&
      (last_touch.slice(*(CAMPAIGN_KEYS + CLICK_KEYS)).any? ||
       (last_touch["unknown_reason"].present? && last_touch["unknown_reason"] != "unavailable"))

    page = acquisition["submission_page"]
    landing_url = page.is_a?(Hash) ? (page["landing_url"].presence || page["url"].presence) : nil
    return nil if landing_url.blank?

    params = query_params(landing_url)
    return nil if params.empty?

    observed_at = acquisition.dig("permission", "observed_at").presence
    fallback = params.merge(
      "landing_url" => safe_url(landing_url, campaign: true),
      "referrer_host" => page["referrer_host"].presence || host(page["referrer"]),
      "observed_at" => observed_at
    ).compact
    fallback["source"] = classify(fallback)
    fallback
  end

  def query_params(url)
    uri = URI.parse(url.to_s)
    URI.decode_www_form(uri.query.to_s).each_with_object({}) do |(key, val), out|
      next unless (CAMPAIGN_KEYS + CLICK_KEYS).include?(key)
      cleaned = val.to_s.strip
      out[key] = cleaned if cleaned.present? && cleaned.length <= 200
    end
  rescue URI::InvalidURIError, ArgumentError
    {}
  end

  def backfill_unavailable_touches!
    counts = { leads_updated: 0, conversions_queued: 0 }
    ::Lead.order(:id).find_each do |lead|
      lead.with_lock do
        meta = lead.metadata.is_a?(Hash) ? lead.metadata.deep_dup : {}
        acquisition = meta["acquisition"]
        fallback = submission_page_fallback(acquisition)
        next unless fallback

        legacy = legacy_attribution(meta["attribution"].is_a?(Hash) ? meta["attribution"] : {}, acquisition: acquisition)
        next if legacy.empty?

        derived_source = ::Leads.derive_source(legacy)
        existing_attr = meta["attribution"].is_a?(Hash) ? meta["attribution"] : {}
        merged_attr = legacy.merge(existing_attr.compact_blank)

        updates = {}
        updates[:source] = derived_source if lead.source == "website_form" && derived_source != "website_form"
        if lead.campaign_name.blank? && legacy["utm_campaign"].present?
          updates[:campaign_name] = legacy["utm_campaign"].to_s.strip.presence
        end
        if merged_attr != existing_attr
          meta["attribution"] = merged_attr
          updates[:metadata] = meta
        end

        next if updates.empty?

        lead.update_columns(updates)
        lead.sync_fts!
        counts[:leads_updated] += 1
        if ::AdConversions.reportable?(lead)
          ::AdConversions::LeadJob.perform_later(lead.id)
          counts[:conversions_queued] += 1
        end
      end
    end
    counts
  end
end
