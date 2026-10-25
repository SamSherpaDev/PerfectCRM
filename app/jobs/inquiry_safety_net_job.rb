class InquirySafetyNetJob < ApplicationJob
  queue_as :default

  def perform
    scanner = Leads::UnlinkedInquiries.new
    scanner.resolve!
    # The report email is opt-in; Today lists the same leads either way.
    return unless Setting.current.inquiry_safety_net_email?

    # Reserve before SMTP, just like reply alerts. Even an uncertain SMTP
    # acknowledgement must never cause a second alert about the same message.
    messages = Message.transaction do
      scanner.messages(unalerted: true).select do |message|
        Leads::UnlinkedInquiries.own_safety_net_lead?(message.conversation.linkable, message) &&
          Message.where(id: message.id, inquiry_alert_attempted_at: nil)
            .update_all(inquiry_alert_attempted_at: Time.current) == 1
      end
    end
    return if messages.empty?

    InquirySafetyNetMailer.unlinked(messages).deliver_now
  end
end
