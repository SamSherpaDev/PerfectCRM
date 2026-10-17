class InquirySafetyNetMailer < ApplicationMailer
  def unlinked(messages)
    @messages = messages
    headers["Auto-Submitted"] = "auto-generated"
    headers["X-Auto-Response-Suppress"] = "All"
    mail(to: Setting.captain_email,
      subject: "Unlinked inquiries: #{messages.size} to review")
  end
end
