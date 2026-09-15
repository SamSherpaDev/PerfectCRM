# frozen_string_literal: true

# Tiny plain-text emphasis for the reply box's basic formatting row:
# *bold* and _italic_ survive into the HTML copy of the email; the text
# copy keeps the markers so nothing is lost in plain-text readers.
module Outbound
  module Emphasis
    def self.to_html(text)
      escaped = ERB::Util.html_escape(text.to_s)
      escaped = escaped.gsub(/\*([^*\n]+)\*/) { "<strong>#{Regexp.last_match(1)}</strong>" }
      escaped = escaped.gsub(/(?<!\w)_([^_\n]+)_(?!\w)/) { "<em>#{Regexp.last_match(1)}</em>" }
      escaped
    end
  end
end
