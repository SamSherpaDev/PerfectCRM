# A permanent address reservation, committed with the outbound message.
# Deleting/archiving a record must never allow another automatic greeting.
class AutomaticFirstReply < ApplicationRecord
  belongs_to :lead, optional: true
  belongs_to :message, optional: true

  def self.skip_reason(lead, email:, excluding_message: nil)
    setting = Setting.current
    return "setting is off" unless setting.auto_first_reply_enabled?
    return "old inquiry" if lead.created_at <= setting.auto_first_reply_enabled_at
    return "not a website inquiry" unless lead.capture_channel == "website_form" && lead.external_ref.to_s.start_with?("website_form:")
    return "invalid email" unless email.length <= 254 && email.match?(URI::MailTo::EMAIL_REGEXP)
    return "address changed" unless lead.effective_recipient_email(email) == email && lead.email.to_s.strip.downcase == email
    domain = email.split("@").last
    return "our own domain" if domain == "sherpaholidays.com" || domain.end_with?(".sherpaholidays.com")
    reserved = %w[example.com example.org example.net example invalid test localhost]
    return "test address" if lead.is_test? || reserved.any? { |name| domain == name || domain.end_with?(".#{name}") }
    return "spam or junk" if lead.spam_score.positive? || lead.suspected_spam? || lead.fit_reason.to_s.match?(/\b(?:spam|junk)\b/i)
    return "inactive inquiry" if lead.archived? || lead.converted? || lead.status == "lost"
    # Use the same identity/people resolution as inbound timelines, including
    # converted leads and addresses explicitly assigned to a client.
    return "existing client" if Mail::Matcher.call([ email ]).linkable.is_a?(Client)
    return "existing client" if Client.where("lower(email) = ?", email).exists? || Person.where("lower(email) = ?", email).where.not(client_id: nil).exists?
    messages = Message.outbound.where.not(id: excluding_message).select(:id, :to_addresses, :cc_addresses, :bcc_addrs)
    # Includes imported sent mail, group sends, and queued manual sends.
    contacted = false
    messages.find_each do |message|
      if (message.to_list + message.cc_list + EmailRedirects.mailboxes(message.bcc_addrs)).any? { |recipient| Mail.extract_addresses(recipient).include?(email) }
        contacted = true
        break
      end
    end
    return "already contacted" if contacted

    nil
  end

  def self.log(lead, reason, message: nil)
    lead.activity_events.create!(kind: "automation", occurred_at: Time.current,
      summary: "Automatic first reply: #{reason}",
      metadata: { "caller" => "perfectcrm", "message_id" => message&.id })
  end

  def claim_delivery!
    self.class.where(id: id, delivery_attempted_at: nil).update_all(delivery_attempted_at: Time.current) == 1
  end

  # The kill switch and late spam verdict apply even if delivery was delayed.
  def delivery_allowed?
    reason = lead ? self.class.skip_reason(lead.reload, email: email, excluding_message: message_id) : "inquiry removed"
    reason ||= "missing placeholder" if message.text_body.match?(/\[missing:/i)
    return true unless reason

    self.class.log(lead, "skipped (#{reason})", message: message) if lead
    message.mark_failed!("Automatic first reply skipped: #{reason}")
    false
  end
end
