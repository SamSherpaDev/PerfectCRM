# Inbound Gmail half (crm-mail-in): every message to or from the captain's
# info@ mailbox lands on the right timeline, threaded, with attachments.
# See README.md, "Mail".
module Mail
  FOLDER = "[Gmail]/All Mail"

  class << self
    # The mailbox address is fixed to the configured value so personal mail
    # can never drift in through a form field.
    def mailbox_address
      ENV.fetch("MAILBOX_ADDRESS", "info@sherpaholidays.com").to_s.strip.downcase.presence || "info@sherpaholidays.com"
    end

    def mailbox_aliases
      base = [ mailbox_address ]
      extra = ENV.fetch("MAILBOX_ALIASES", "").split(",").map { |value| value.strip.downcase }.reject(&:blank?)
      (base + extra).uniq
    end

    # HARD RULE: keep only messages where a mailbox address appears in any
    # delivered header. Everything else is personal mail and is skipped
    # without storing it.
    def keeps?(headers)
      wanted = mailbox_aliases
      candidates = []
      %w[from to cc bcc delivered-to x-original-to].each do |key|
        values = headers[key] || headers[key.to_s.downcase] || headers[key.to_s.upcase]
        Array(values).each do |value|
          candidates.concat(extract_addresses(value.to_s))
          candidates << value.to_s.strip.downcase
        end
      end
      raw = headers.values.flatten.map(&:to_s).join(" ").downcase
      candidates.map!(&:downcase)
      wanted.any? { |address| candidates.include?(address) || raw.include?(address) }
    end

    def extract_addresses(text)
      text.to_s.scan(/[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}/).map(&:downcase)
    end

    def direction_for(from_addresses)
      froms = Array(from_addresses).map { |value| value.to_s.downcase }
      return "out" if froms.any? { |address| mailbox_aliases.include?(address) }

      "in"
    end
  end
end
