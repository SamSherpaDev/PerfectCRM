# The 7am Pacific email: what is waiting on the captain today. Plain text,
# short, with deep links. Sent to the first allowlisted address.
class CaptainDigestMailer < ApplicationMailer
  default from: "PerfectCRM <info@sherpaholidays.com>"

  def morning(today: Date.current)
    @today = today
    @summary = Today::Summary.new(today: today)
    mail(to: recipient, subject: "Today: #{@today.strftime('%-b %-d')} · #{headline}")
  end

  private

  def headline
    due = @summary.followups_due.count
    over = @summary.overdue.count
    "#{over} overdue, #{due} due"
  end

  def recipient
    ENV.fetch("ALLOWED_GOOGLE_EMAILS", "info@sherpaholidays.com").split(/[,\s]+/).reject(&:blank?).first
  end
end
