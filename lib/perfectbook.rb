# PerfectBook link: the CRM reads bookings and the trip catalog from
# PerfectBook's versioned read-only API and never writes money data.
# See README.md, "PerfectBook connection".
module PerfectBook
  DEFAULT_BASE_URL = "https://perfectbook.sherpaholidays.com"

  def self.table_name_prefix
    "perfectbook_"
  end

  class << self
    def base_url
      ENV.fetch("PERFECTBOOK_BASE_URL", DEFAULT_BASE_URL).to_s.sub(%r{/+\z}, "").presence || DEFAULT_BASE_URL
    end

    def api_token
      ENV["PERFECTBOOK_API_TOKEN"].to_s
    end

    def configured?
      api_token.present?
    end

    # Public contact page on PerfectBook for the "Open in PerfectBook" link.
    def contact_url(id)
      "#{base_url}/contacts/#{id}"
    end
  end
end

require_relative "perfectbook/error"
require_relative "perfectbook/circuit"
require_relative "perfectbook/client"
require_relative "perfectbook/catalog"
