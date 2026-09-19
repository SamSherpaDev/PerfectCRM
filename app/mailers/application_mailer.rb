class ApplicationMailer < ActionMailer::Base
  default from: ENV.fetch("MAIL_FROM", "info@sherpaholidays.com")
  layout "mailer"

  private

  # The signature logo ships embedded in the mail itself (Content-ID),
  # never hosted on a public URL, so it renders without a download-images
  # prompt. Attached only when the HTML signature references it.
  def attach_signature_logo(setting, signature_html)
    return unless EmailSignature.logo_attached?(setting)
    return unless signature_html.include?("cid:#{EmailSignature::CID}")

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
