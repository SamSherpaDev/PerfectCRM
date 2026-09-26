# Quote emails, sent through the same SMTP settings as every other
# CRM mail (config/environments/production.rb), always from info@.
class QuoteMailer < ApplicationMailer
  default from: "SherpaHolidays <info@sherpaholidays.com>"
  helper ApplicationHelper

  # The quote itself: rendered body plus the Washi PDF and tap-to-accept link.
  def quote_email(quote)
    @quote = quote
    @accept_url = public_quote_url(@quote.accept_token)
    attachments["quote-#{@quote.reference}.pdf"] =
      QuotePdf.new(@quote, accept_url: @accept_url).render
    setting = Setting.current
    @signature_text = EmailSignature.text_for(setting).to_s
    @signature_html = EmailSignature.html_for(setting)
    attach_signature_logo(setting, @signature_html)
    mail(to: @quote.owner_email,
      subject: "Your SherpaHolidays quote #{@quote.reference} for #{@quote.subject_label}")
  end

  # Tells the captain the moment a client taps accept.
  def accepted_notice(quote)
    @quote = quote
    mail(to: "info@sherpaholidays.com",
      subject: "Accepted: quote #{@quote.reference} (#{@quote.owner_name})")
  end
end
