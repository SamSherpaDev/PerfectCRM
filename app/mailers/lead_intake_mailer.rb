# The email copy of every website inquiry, sent to the captain with
# Reply-To the visitor so one tap answers them. Attribution stays in lead
# metadata; the displayed page URL strips tracking query parameters.
class LeadIntakeMailer < ApplicationMailer
  def self.real_inquiry?(lead)
    lead.present? &&
      !lead.archived? &&
      lead.spam_marked_at.nil? &&
      !lead.safety_net_inquiry? &&
      !lead.external_ref.to_s.start_with?("mail_message:")
  end

  def inquiry_copy(lead)
    return unless self.class.real_inquiry?(lead)

    @lead = lead
    @page_url = displayed_page_url(lead)
    @phone = lead.phone_raw.presence || lead.phone.presence
    @tel_href = lead.phone.presence || @phone.to_s.gsub(/[^\d+]/, "").presence
    @check_first = lead.spam_score.to_i.positive? || lead.suspected_spam?

    first_name = lead.name.to_s.split.first.presence || lead.name.to_s.strip.presence || "New inquiry"
    trip = lead.trip_title.presence || lead.trip_interest.presence || lead.trip_handle.presence || "not sure yet"
    verb = @tel_href.present? ? "call" : "reply"
    prefix = @check_first ? "Check, then #{verb}" : "#{verb.capitalize} now"
    subject = "#{prefix}: #{first_name} - #{trip}"

    headers["Auto-Submitted"] = "auto-generated"
    headers["X-Auto-Response-Suppress"] = "All"
    mail(
      to: "info@sherpaholidays.com",
      reply_to: lead.email,
      subject: subject
    )
  end

  private

  def displayed_page_url(lead)
    page = lead.metadata.is_a?(Hash) ? lead.metadata["page"] : nil
    return unless page.is_a?(Hash) && page["url"].is_a?(String)

    uri = URI.parse(page["url"])
    if uri.query
      parameters = URI.decode_www_form(uri.query).reject do |name, _|
        name = name.downcase
        name.in?(%w[gclid gbraid wbraid]) || name.start_with?("utm_")
      end
      uri.query = parameters.empty? ? nil : URI.encode_www_form(parameters)
    end
    uri.to_s.presence
  rescue URI::InvalidURIError, ArgumentError
    nil
  end
end
