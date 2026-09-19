# frozen_string_literal: true

# The Settings signature in both shapes: plain text for text mail parts and
# the {{signature}} placeholder, and the app-owned HTML block (signature
# lines plus the uploaded logo by Content-ID) for HTML mail parts.
#
module EmailSignature
  CID = "signature-logo@perfectcrm"
  MAX_LOGO_BYTES = 500.kilobytes
  LOGO_TYPES = %w[image/png image/jpeg image/gif].freeze

  # The logo fits inside this box, preserving aspect ratio and never
  # upscaling a small mark.
  LOGO_MAX_WIDTH = 120
  LOGO_MAX_HEIGHT = 44

  # Fixed brand tokens for the mail block (docs/DESIGN.md through
  # email-safe stand-ins): Georgia is Gelasio's metric twin for the name,
  # Arial/Helvetica for the rest; ink on the white every mail client shows.
  NAME_COLOR = "#14110e"
  DETAIL_COLOR = "#3d3226"
  RULE_COLOR = "#c96f1a"

  ALLOWED_TAGS = %w[p br div span a b strong i em u table tbody tr td img].freeze
  ALLOWED_ATTRIBUTES = %w[href src alt width height style].freeze
  STYLE_PROPERTIES = %w[font-size font-family color].freeze

  class << self
    def text_for(setting)
      text_from_html(setting.email_signature_html).presence || setting.email_signature.presence
    end

    # The signature as editable lines: what the text part and
    # {{signature}} carry, and what the HTML block renders.
    def lines_for(setting)
      text_for(setting).to_s.lines.map(&:strip).reject(&:blank?)
    end

    # The app-owned HTML signature block: a two-cell table with the logo
    # beside the name lines, all styles inline for mail clients. The logo
    # image, when attached, is referenced through logo_src (a cid: URL in
    # mail, a blob path in the Settings preview). Empty when nothing is
    # configured.
    def html_for(setting, logo_src: "cid:#{CID}")
      lines = lines_for(setting)
      return "" if lines.empty?

      name, *details = lines
      detail_rows = details.map do |line|
        %(<div style="font-size:13px;line-height:19px;color:#{DETAIL_COLOR};">#{ERB::Util.html_escape(line)}</div>)
      end.join
      content = if setting.email_signature_html.present?
        sanitize(setting.email_signature_html)
      else
        %(<div style="font-family:Georgia,'Times New Roman',serif;font-size:16px;line-height:22px;color:#{NAME_COLOR};font-weight:bold;">#{ERB::Util.html_escape(name)}</div>#{detail_rows})
      end
      <<~HTML.strip
        <table role="presentation" cellpadding="0" cellspacing="0" border="0" style="border-collapse:collapse;margin-top:20px;font-family:Arial,Helvetica,sans-serif;"><tr>#{logo_cell(setting, logo_src: logo_src)}<td style="padding:2px 0 2px 16px;vertical-align:middle;border-left:2px solid #{RULE_COLOR};font-size:13px;line-height:19px;color:#{DETAIL_COLOR};">#{content}</td></tr></table>
      HTML
    end

    # Natural logo dimensions [width, height]: blob metadata first, else a
    # small read of the PNG/GIF/JPEG header bytes, so rendering never
    # depends on the Active Storage analyzer. Nil when unknown.
    def logo_dimensions(blob)
      width = blob.metadata[:width] || blob.metadata["width"]
      height = blob.metadata[:height] || blob.metadata["height"]
      return [ width.to_i, height.to_i ] if width.to_i.positive? && height.to_i.positive?

      parse_image_dimensions(blob.download)
    rescue StandardError
      nil
    end

    # The logo fitted inside the LOGO_MAX box, preserving aspect ratio and
    # never upscaling. Nil when no logo is attached or its size is unknown.
    def logo_box(setting)
      return nil unless logo_attached?(setting)

      dimensions = logo_dimensions(setting.signature_logo.blob)
      return nil if dimensions.nil?

      width, height = dimensions
      return nil unless width.positive? && height.positive?

      scale = [ LOGO_MAX_WIDTH / width.to_f, LOGO_MAX_HEIGHT / height.to_f, 1.0 ].min
      [ (width * scale).round, (height * scale).round ]
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

    # The logo cell of the signature table, or nothing when no logo is
    # attached: then the text column keeps its ochre rule on its own.
    def logo_cell(setting, logo_src:)
      return "" unless logo_attached?(setting) && logo_src.present?

      src = ERB::Util.html_escape(logo_src)
      fitted = logo_box(setting)
      img = if fitted
        width, height = fitted
        %(<img src="#{src}" alt="Sherpa Holidays" width="#{width}" height="#{height}" style="display:block;width:#{width}px;height:#{height}px;border:0;">)
      else
        %(<img src="#{src}" alt="Sherpa Holidays" style="display:block;border:0;">)
      end
      %(<td style="padding:0 16px 0 0;vertical-align:middle;">#{img}</td>)
    end

    def parse_image_dimensions(bytes)
      bytes = bytes.b
      return parse_png_dimensions(bytes) if bytes.start_with?("\x89PNG\r\n\x1A\n".b)
      return parse_gif_dimensions(bytes) if bytes.start_with?("GIF87a".b, "GIF89a".b)
      return parse_jpeg_dimensions(bytes) if bytes.bytesize > 2 && bytes.getbyte(0) == 0xFF && bytes.getbyte(1) == 0xD8

      nil
    end

    def parse_png_dimensions(bytes)
      return nil if bytes.bytesize < 24

      width = bytes.byteslice(16, 4).unpack1("N")
      height = bytes.byteslice(20, 4).unpack1("N")
      width.positive? && height.positive? ? [ width, height ] : nil
    end

    def parse_gif_dimensions(bytes)
      return nil if bytes.bytesize < 10

      width = bytes.byteslice(6, 2).unpack1("v")
      height = bytes.byteslice(8, 2).unpack1("v")
      width.positive? && height.positive? ? [ width, height ] : nil
    end

    # JPEG: walk the markers to the first start-of-frame, which carries the
    # dimensions. Standalone markers carry no length and are skipped.
    def parse_jpeg_dimensions(bytes)
      offset = 2
      while offset + 3 < bytes.bytesize
        return nil unless bytes.getbyte(offset) == 0xFF

        marker = bytes.getbyte(offset + 1)
        if marker == 0xFF
          offset += 1
          next
        end
        if marker == 0x01 || (0xD0..0xD9).cover?(marker)
          offset += 2
          next
        end
        length = bytes.byteslice(offset + 2, 2)&.unpack1("n")
        return nil if length.nil? || length < 2
        if [ 0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF ].include?(marker)
          return nil if offset + 8 >= bytes.bytesize

          height = bytes.byteslice(offset + 5, 2).unpack1("n")
          width = bytes.byteslice(offset + 7, 2).unpack1("n")
          return width.positive? && height.positive? ? [ width, height ] : nil
        end
        offset += 2 + length
      end
      nil
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
