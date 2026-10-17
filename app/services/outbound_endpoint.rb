require "uri"

# Validate before constructing a request or attaching credentials. HTTP
# redirects are never followed by these clients. Additional deployments,
# including private HTTPS services, require an explicit environment allowlist.
module OutboundEndpoint
  DEFAULT_ORIGINS = {
    "AI" => %w[https://api.openai.com https://openrouter.ai],
    "PERFECTBOOK" => %w[https://perfectbook.sherpaholidays.com],
    "LEAD_WEBHOOK" => []
  }.freeze

  def self.for_service!(url, service:)
    origins = DEFAULT_ORIGINS.fetch(service) + ENV.fetch("#{service}_ALLOWED_ORIGINS", "").split(",").map(&:strip)
    validate!(url, allowed_origins: origins)
  end

  def self.validate!(url, allowed_origins:)
    uri = URI.parse(url.to_s)
    valid = uri.is_a?(URI::HTTPS) && uri.hostname.present? && uri.userinfo.nil? && uri.fragment.nil?
    allowed = valid && allowed_origins.any? do |origin|
      candidate = URI.parse(origin)
      candidate.is_a?(URI::HTTPS) && candidate.userinfo.nil? && candidate.query.nil? && candidate.fragment.nil? &&
        [ "", "/" ].include?(candidate.path) && candidate.hostname&.downcase == uri.hostname.downcase && candidate.port == uri.port
    end
    raise ArgumentError, "must use HTTPS and an approved service origin" unless allowed

    uri
  rescue URI::InvalidURIError
    raise ArgumentError, "must use HTTPS and an approved service origin"
  end
end
