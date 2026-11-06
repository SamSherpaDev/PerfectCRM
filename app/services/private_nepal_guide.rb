# The single approved guide edition, not a marketing or workflow service.
module PrivateNepalGuide
  EDITION = "private-nepal-2026-11-05".freeze
  FROM = "info@sherpaholidays.com".freeze
  SUBJECT = "Your private Nepal journey guide".freeze
  PDF_PLACEHOLDER = "[Private Nepal journey guide - final approved PDF link]".freeze
  SEND_TOOL_NOTE = " If a marketing send tool is used, include its working unsubscribe link as well.".freeze

  class Unavailable < StandardError; end

  def self.configuration
    Rails.application.config_for(:private_nepal_guide)
  end

  def self.available?
    config = configuration
    config[:enabled] == true && valid_pdf_url?(config[:pdf_url]) && Outbound::Composer.from_address == FROM
  end

  def self.valid_pdf_url?(value)
    uri = URI.parse(value.to_s)
    uri.is_a?(URI::HTTPS) && %w[www.sherpaholidays.com cdn.shopify.com].include?(uri.host) &&
      uri.port == 443 && uri.userinfo.nil? && uri.query.nil? && uri.fragment.nil? &&
      uri.path.end_with?(".pdf") && !value.to_s.match?(/[\s\[\]<>]/)
  rescue URI::InvalidURIError
    false
  end

  def self.content
    raise Unavailable unless available?

    # Preserve Marketmate's approved body, including signature/commercial footer.
    # The review/timing/header block and the send-tool instruction are operator
    # guidance, not outgoing content; this info@ SMTP path is not a send tool.
    approved = Rails.root.join("config/private_nepal_guide/D0.txt").read
    body = approved.split("\n\n", 2).last.sub(PDF_PLACEHOLDER, configuration[:pdf_url]).sub(SEND_TOOL_NOTE, "")
    { subject: SUBJECT, body: body }
  end
end
