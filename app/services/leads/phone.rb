module Leads
  # Normalize the formats used by the US storefront without guessing an
  # international calling code. Explicit + numbers retain the intake's existing
  # 7–15 digit contract. This is formatting, not proof a number is reachable.
  module Phone
    def self.normalize(raw, country: nil)
      compact = raw.to_s.gsub(/[\s\-().]/, "")
      return compact if compact.match?(/\A\+[1-9]\d{6,14}\z/)
      return nil unless country.blank? || country.to_s.strip.upcase.in?(%w[US USA UNITED\ STATES UNITED\ STATES\ OF\ AMERICA])

      if compact.match?(/\A\d{10}\z/)
        "+1#{compact}"
      elsif compact.match?(/\A1\d{10}\z/)
        "+#{compact}"
      end
    end

    # Strict quiz gate validation only; leave ordinary inquiry formatting alone.
    def self.parse_quiz(raw, country: nil)
      return nil unless raw.is_a?(String) && raw.length <= 100
      return nil unless raw.match?(/\A\+?[0-9\s().-]+\z/)

      region = country.to_s.strip.upcase.presence || "US"
      region = "US" if region.in?([ "USA", "UNITED STATES", "UNITED STATES OF AMERICA" ])
      return nil unless raw.strip.start_with?("+") || Phonelib.phone_data.key?(region)

      parsed = Phonelib.parse(raw, region)
      parsed.full_e164 if parsed.valid? && parsed.extension.blank?
    end

    def self.format(raw, country: nil)
      value = raw.presence
      return nil unless value

      digits = normalize(value, country: country)&.[](/\A\+1(\d{10})\z/, 1)
      digits ? "#{digits[0, 3]}-#{digits[3, 3]}-#{digits[6, 4]}" : value
    end
  end
end
