# frozen_string_literal: true

# Two-way sensitive-data guard: passport numbers, dates of birth, and card
# numbers are redacted before any text reaches a provider and filtered out
# of any text a provider returns. When in doubt it redacts rather than echoes.
module Ai
  module Scrub
    PATTERNS = [
      # Passport labels with a following code. The code must contain a digit
      # so the replacement token itself never re-matches.
      /\bpassport[^\n]{0,20}[A-Z0-9]*\d[A-Z0-9]{5,}/i,
      # ISO-ish and written dates of birth near a DOB label.
      /\b(?:dob|date of birth|born)[^\n]{0,24}\d{1,4}[\/\-. ]\d{1,2}[\/\-. ]\d{1,4}/i,
      # Long digit runs with internal spaces/dashes (passport, card, DOB
      # numerics). Starts and ends on a digit so surrounding spaces survive.
      /(?<!\d)(?:\d[ \-]?){8,18}\d(?!\d)/
    ].freeze

    REPLACEMENT = "[redacted]".freeze

    def self.scrub(text)
      PATTERNS.reduce(text.to_s) { |out, pattern| out.gsub(pattern, REPLACEMENT) }
    end

    def self.scrubbed?(text)
      text.to_s.include?(REPLACEMENT)
    end

    # True when the text still carries a raw sensitive-looking value.
    def self.sensitive?(text)
      scrub(text) != text.to_s
    end
  end
end
