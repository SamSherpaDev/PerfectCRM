module Leads
  # Normalize the formats used by the US storefront without guessing an
  # international calling code. Explicit + numbers retain the intake's existing
  # 7–15 digit contract. This is formatting, not proof a number is reachable.
  module Phone
    SEPARATORS = /[\s\-().]/
    US_COUNTRIES = [ "US", "USA", "UNITED STATES", "UNITED STATES OF AMERICA" ].freeze

    def self.normalize(raw, country: nil)
      compact = raw.to_s.gsub(SEPARATORS, "")
      return compact if compact.match?(/\A\+[1-9]\d{6,14}\z/)
      return nil unless us_default?(country)

      if compact.match?(/\A\d{10}\z/)
        "+1#{compact}"
      elsif compact.match?(/\A1\d{10}\z/)
        "+#{compact}"
      end
    end

    def self.format(raw, country: nil)
      value = raw.presence
      return nil unless value

      compact = value.to_s.gsub(SEPARATORS, "")
      digits = compact[/\A\+?1(\d{10})\z/, 1] || (compact[/\A\d{10}\z/] if us_default?(country))
      digits ? "#{digits[0, 3]}-#{digits[3, 3]}-#{digits[6, 4]}" : value
    end

    def self.us_default?(country)
      country.blank? || country.to_s.strip.upcase.in?(US_COUNTRIES)
    end
    private_class_method :us_default?
  end
end
