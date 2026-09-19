# Quote emails, sent through the same SMTP settings as every other
# CRM mail (config/environments/production.rb), always from info@.
class QuoteMailer < ApplicationMailer
  default from: "Sherpa Holidays <info@sherpaholidays.com>"
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
    attach_signature_logo(setting)
    mail(to: @quote.owner_email,
      subject: "Your Sherpa Holidays quote #{@quote.reference} — #{@quote.subject_label}")
  end

  # Tells the captain the moment a client taps accept.
  def accepted_notice(quote)
    @quote = quote
    mail(to: "info@sherpaholidays.com",
      subject: "Accepted: quote #{@quote.reference} (#{@quote.owner_name})")
  end

  private

  # The logo ships embedded in the mail itself (Content-ID), never hosted
  # on a public URL, so it renders without a download-images prompt.
  def attach_signature_logo(setting)
    return unless EmailSignature.logo_attached?(setting)
    return unless @signature_html.include?("cid:#{EmailSignature::CID}")

    blob = setting.signature_logo.blob
    attachments.inline["signature-logo#{logo_extension(blob.content_type)}"] = {
      mime_type: blob.content_type,
      content: blob.download,
      content_id: "<#{EmailSignature::CID}>"
    }
  end

  def logo_extension(content_type)
    case content_type
    when "image/png" then ".png"
    when "image/gif" then ".gif"
    else ".jpg"
    end
  end
end
