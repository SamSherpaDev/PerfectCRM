# frozen_string_literal: true

# The Settings signature in both shapes: plain text for text mail parts and
# the {{signature}} placeholder, and sanitized HTML with the uploaded logo
# embedded by Content-ID for HTML mail parts.
#
# Pasted Outlook HTML is scrubbed on an explicit allowlist (what Outlook
# emits: p, br, div, span, a with href, b, strong, i, em, u, table, tbody,
# tr, td, img, plus font-size, font-family, and color inline styles).
# Scripts, style/link tags, forms, and comments (Outlook conditional
# markup) go; every <img> becomes the uploaded logo referenced by cid, or
# is dropped when no logo is attached, so no external image URL ever ships.
module EmailSignature
  CID = "signature-logo@perfectcrm"
  MAX_LOGO_BYTES = 500.kilobytes
  LOGO_TYPES = %w[image/png image/jpeg image/gif].freeze

  ALLOWED_TAGS = %w[p br div span a b strong i em u table tbody tr td img].freeze
  ALLOWED_ATTRIBUTES = %w[href src alt width height style].freeze
  STYLE_PROPERTIES = %w[font-size font-family color].freeze

  class << self
    # Plain-text signature: the saved lines, or derived from the HTML when
    # only HTML was supplied. Blank when nothing is configured.
    def text_for(setting)
      setting.email_signature.presence || text_from_html(setting.email_signature_html).presence
    end

    # Full HTML signature block for an HTML mail part. The logo image, when
    # attached, is referenced through logo_src (a cid: URL in mail, a blob
    # path in the Settings preview). Empty when nothing is configured.
    def html_for(setting, logo_src: "cid:#{CID}")
      sanitized = sanitize(setting.email_signature_html)
      rendered = sanitized.present? ? with_logo(sanitized, setting, logo_src: logo_src) : ""
      if rendered.blank? && text_for(setting).present?
        generated(text_for(setting), setting, logo_src: logo_src)
      else
        rendered
      end
    end

    # The Rails sanitizer on the explicit allowlist, then a Loofah pass for
    # the rules the sanitizer cannot express: style limited to font-size,
    # font-family, and color, href limited to http/https/mailto/tel, numeric
    # dimensions only, no
    # comments (Outlook conditional markup hides tables in them).
    def sanitize(html)
      fragment = Loofah.fragment(html.to_s)
      fragment.css("script, style, form, iframe, object, embed").remove
      clean = Rails::Html::SafeListSanitizer.new.sanitize(
        fragment.to_html, tags: ALLOWED_TAGS, attributes: ALLOWED_ATTRIBUTES
      )
      fragment = Loofah.fragment(clean)
      fragment.xpath("//comment()").remove
      fragment.css("*").each do |node|
        scrub_style(node)
        scrub_href(node)
        scrub_dimensions(node)
      end
      fragment.to_html.strip
    end

    # Best-effort text from sanitized HTML, for the text fallback when only
    # HTML was supplied.
    def text_from_html(html)
      clean = sanitize(html.to_s)
      return "" if clean.blank?

      Loofah.fragment(clean).to_text(encode_special_chars: false).tr("\u00A0", " ")
        .lines.map(&:strip).reject(&:blank?).join("\n")
    end

    # Split a composed text body around its text signature so the HTML part
    # can carry the HTML signature exactly once at the same spot: trailing
    # when the composer appended it, inline where a {{signature}} template
    # placeholder rendered it. Returns [before, after] (after empty when
    # appended) or nil when the signature is absent.
    def split_body(text_body, template_id: nil)
      setting = Setting.current
      text = text_for(setting).to_s
      return nil if text.blank?

      needle = text.strip
      body = text_body.to_s
      if template_carries_signature?(template_id)
        index = body.index(needle)
        return nil if index.nil?

        [ body[0...index], body[(index + needle.length)..] ]
      else
        stripped = body.rstrip
        return nil unless stripped.end_with?(needle)

        [ stripped[0...stripped.length - needle.length].rstrip, "" ]
      end
    end

    # The stored logo only: an in-memory attach from a failed validation
    # has no bytes to serve or embed yet.
    def logo_attached?(setting)
      setting.signature_logo.attached? && setting.signature_logo.attachment.persisted?
    end

    # A template that renders {{signature}} signs its own body, so nothing
    # appends a second signature after it.
    def template_carries_signature?(template_id)
      return false if template_id.blank?

      TemplateRenderer.placeholders_in(Template.where(id: template_id).pick(:body)).include?("signature")
    end

    private

    # Every <img> becomes the uploaded logo (keeping a plain-number width
    # or height from the pasted markup), or is dropped when no logo is
    # attached, so the only image that ever ships is the uploaded one.
    def with_logo(html, setting, logo_src:)
      fragment = Loofah.fragment(html)
      fragment.css("img").each do |node|
        if logo_attached?(setting) && logo_src.present?
          replacement = logo_img_tag(setting, logo_src: logo_src)
          width = node["width"]
          height = node["height"]
          replacement["width"] = width if width.to_s.match?(/\A\d+\z/)
          replacement["height"] = height if height.to_s.match?(/\A\d+\z/)
          node.replace(replacement)
        else
          node.remove
        end
      end
      fragment.to_html
    end

    def logo_img_tag(setting, logo_src:)
      doc = Loofah.fragment("")
      node = Nokogiri::XML::Node.new("img", doc)
      node["src"] = logo_src
      node["alt"] = "Sherpa Holidays"
      node["width"] = logo_display_width(setting).to_s
      node
    end

    def logo_display_width(setting)
      natural = setting.signature_logo.blob.metadata[:width].to_i
      return 200 if natural <= 0

      [ natural, 200 ].min
    end

    # Build-from-text path: the saved lines plus the uploaded logo.
    def generated(text, setting, logo_src:)
      lines = text.to_s.lines.map(&:strip).reject(&:blank?)
      paragraphs = lines.map { |line| "<p>#{ERB::Util.html_escape(line)}</p>" }.join("\n")
      logo = logo_attached?(setting) && logo_src.present? ?
        "#{logo_img_tag(setting, logo_src: logo_src).to_html}\n" : ""
      "#{logo}#{paragraphs}"
    end

    def scrub_style(node)
      style = node["style"]
      return if style.nil?

      kept = style.to_s.split(";").map(&:strip).filter_map do |declaration|
        name, _, value = declaration.partition(":")
        next if name.blank? || value.blank?
        next unless STYLE_PROPERTIES.include?(name.strip.downcase)
        next if value.match?(/url\s*\(|expression|javascript:|behaviour|behavior/i)

        "#{name.strip}: #{value.strip}"
      end
      kept.any? ? node["style"] = kept.join("; ") : node.remove_attribute("style")
    end

    def scrub_href(node)
      return unless node.name == "a" && node["href"]

      node.remove_attribute("href") unless node["href"].match?(/\A(https?|mailto|tel):/i)
    end

    def scrub_dimensions(node)
      %w[width height].each do |attr|
        value = node[attr]
        node.remove_attribute(attr) if !value.nil? && !value.match?(/\A\d+\z/)
      end
    end
  end
end
