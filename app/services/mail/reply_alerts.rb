module Mail
  # Only live sync asks for alerts. History imports and triage never do.
  module ReplyAlerts
    HEADERS = %w[auto-submitted x-autoreply x-autorespond
      x-ms-exchange-inbox-rules-loop return-path content-type].freeze

    def self.eligible?(parsed, provider)
      return false if provider[:message_id].blank?
      return false unless Mail.direction_for(parsed.from_addresses) == "in"
      return false if Array(parsed.from_addresses).any? { |email| email.to_s.match?(/@(?:[^@]+\.)?sherpaholidays\.com\z/i) }
      return false if automatic?(parsed.from_addresses, parsed.subject, parsed.headers)

      owner = Matcher.call(parsed.from_addresses).linkable
      owner.is_a?(::Lead) || owner.is_a?(::Client)
    end

    def self.automatic?(from_addresses, subject, raw_headers)
      return true if Array(from_addresses).any? { |email| email.to_s.match?(/\A(?:mailer-daemon|postmaster)@/i) }
      headers = (raw_headers || {}).transform_keys { |key| key.to_s.downcase }
      auto = Array(headers["auto-submitted"]).join.strip
      return true if auto.present? && !auto.casecmp?("no")
      return true if %w[x-autoreply x-autorespond x-ms-exchange-inbox-rules-loop].any? { |key| Array(headers[key]).any?(&:present?) }
      return true if Array(headers["return-path"]).any? { |value| value.to_s.strip.empty? || value.to_s.strip == "<>" }
      return true if Array(headers["content-type"]).join.match?(/report-type\s*=\s*["']?delivery-status|message\/delivery-status/i)

      subject.to_s.match?(/\A(?:automatic reply|auto(?:matic)?[- ]response|out of (?:the )?office|undeliverable|delivery (?:status notification|failure)|mail delivery failed)\b/i)
    end
  end
end
