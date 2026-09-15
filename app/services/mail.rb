require "mail"

module Mail
  FOLDER = "[Gmail]/All Mail"

  class << self
    def mailbox_address
      ENV.fetch("MAILBOX_ADDRESS", "info@sherpaholidays.com").to_s.strip.downcase.presence || "info@sherpaholidays.com"
    end

    def keeps?(headers)
      headers = headers.transform_keys { |key| key.to_s.downcase }
      %w[from to cc bcc delivered-to x-original-to].any? do |key|
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
