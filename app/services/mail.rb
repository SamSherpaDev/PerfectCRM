require "mail"

module Mail
  # Shared inbound-mail errors. The Microsoft Graph reader raises these so
  # jobs and controllers handle provider failures uniformly.
  class GraphError < StandardError; end
  class NotConfiguredError < GraphError; end
  # Transient transport/Graph failures: jobs record them and retry.
  class ConnectionError < GraphError; end
  # The captain revoked access or the grant expired: jobs record it on
  # mailbox_last_error and stop quietly so Settings can offer reconnect.
  class GrantRevokedError < GraphError; end
  # The Microsoft account that approved the connection is not the mailbox
  # this CRM reads, so the grant is refused instead of stored.
  class WrongMailboxError < GraphError; end

  # The headers that can name a recipient: the message's own recipient
  # lists plus the delivery headers a hidden Bcc leaves behind. Nothing
  # else decides whether mail is kept.
  RECIPIENT_HEADERS = %w[from to cc bcc delivered-to x-original-to x-envelope-to].freeze

  class << self
    def mailbox_address
      ENV.fetch("MAILBOX_ADDRESS", "info@sherpaholidays.com").to_s.strip.downcase.presence || "info@sherpaholidays.com"
    end

    def keeps?(headers)
      headers = headers.transform_keys { |key| key.to_s.downcase }
      RECIPIENT_HEADERS.any? do |key|
        Array(headers[key]).any? { |value| extract_addresses(value).include?(mailbox_address) }
      end
    end

    def extract_addresses(text)
      ::Mail::AddressList.new(text.to_s).addresses.map { |address| address.address.to_s.downcase }
    rescue ::Mail::Field::ParseError
      []
    end

    def direction_for(from_addresses)
      Array(from_addresses).any? { |value| value.to_s.downcase == mailbox_address } ? "out" : "in"
    end

    def counterparties(parsed)
      addresses = direction_for(parsed.from_addresses) == "in" ? parsed.from_addresses : parsed.to_addresses + parsed.cc_addresses + Array(parsed.headers["bcc"])
      Array(addresses).reject { |value| value == mailbox_address }.uniq
    end
  end
end
