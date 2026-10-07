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
  end
end
