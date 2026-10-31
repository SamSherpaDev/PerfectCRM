module Mail
  # Only live sync asks for alerts. History imports and triage never do.
  module ReplyAlerts
    HEADERS = %w[auto-submitted x-autoreply x-autorespond
      x-ms-exchange-inbox-rules-loop return-path content-type].freeze

    def self.eligible?(parsed, provider)
      return false if provider[:message_id].blank?
      return false unless Mail.direction_for(parsed.from_addresses) == "in"
      return false unless reply?(parsed.from_addresses, parsed.subject, parsed.headers)

      owner = Matcher.call(parsed.from_addresses).linkable
      owner.is_a?(::Lead) || owner.is_a?(::Client)
    end

    def self.reply?(from_addresses, subject, raw_headers)
      return false if Array(from_addresses).any? do |email|
        email.to_s.match?(/@(?:[^@]+\.)?sherpaholidays\.com\z/i) ||
          email.to_s.match?(/\A(?:mailer-daemon|postmaster)@/i)
      end
      headers = (raw_headers || {}).transform_keys { |key| key.to_s.downcase }
      auto = Array(headers["auto-submitted"]).join.strip
      return false if auto.present? && !auto.casecmp?("no")
      return false if %w[x-autoreply x-autorespond x-ms-exchange-inbox-rules-loop].any? { |key| Array(headers[key]).any?(&:present?) }
      return false if Array(headers["return-path"]).any? { |value| value.to_s.strip.empty? || value.to_s.strip == "<>" }
      return false if Array(headers["content-type"]).join.match?(/report-type\s*=\s*["']?delivery-status|message\/delivery-status/i)

      !subject.to_s.match?(/\A(?:automatic reply|auto(?:matic)?[- ]response|out of (?:the )?office|undeliverable|delivery (?:status notification|failure)|mail delivery failed)\b/i)
    end
  end
end
