# The email copy of every website inquiry, sent to the captain with
# Reply-To the visitor so one tap answers them. Attribution stays in lead
# metadata; the displayed page URL strips tracking query parameters.
class LeadIntakeMailer < ApplicationMailer
  def inquiry_copy(lead)
    @lead = lead
    @page_url = displayed_page_url(lead)

    subject = "New inquiry from #{lead.name}: #{lead.trip_title.presence || 'not sure yet'}"
    subject = "[check] #{subject}" if lead.suspected_spam?

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
