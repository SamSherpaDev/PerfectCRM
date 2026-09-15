require "rails/html/sanitizer"

# Sanitizes inbound HTML bodies so the timeline can render them safely.
# Allows basic formatting and links; strips scripts, styles, forms, and
# event handlers. Plain-text bodies pass through untouched.
module Mail
  class Sanitizer
    ALLOWED_TAGS = %w[p br div span strong em b i u a ul ol li blockquote pre code hr h1 h2 h3 h4 table thead tbody tr th td].freeze
    ALLOWED_ATTRIBUTES = %w[href title].freeze

    def self.clean(html)
      new.clean(html)
    end

    def clean(html)
      raw = html.to_s
      return "" if raw.blank?

      scrubbed = ::Rails::Html::SafeListSanitizer.new.sanitize(
        raw, tags: ALLOWED_TAGS, attributes: ALLOWED_ATTRIBUTES
      )
      # Force links to open safely; the sanitizer keeps href but not target.
      scrubbed.gsub(/<a(\s[^>]*)?>/i) do
        attrs = Regexp.last_match(1).to_s
        attrs += ' target="_blank" rel="noopener"' unless attrs.include?("target=")
        "<a#{attrs}>"
      end
    end
  end
end
