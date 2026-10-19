class InquirySafetyNetJob < ApplicationJob
  queue_as :default

  def perform
    scanner = Leads::UnlinkedInquiries.new
    scanner.resolve! if scanner.respond_to?(:resolve!)

    # Reserve before SMTP, just like reply alerts. Even an uncertain SMTP
    # acknowledgement must never cause a second alert about the same message.
    messages = Message.transaction do
      scanner.messages(unalerted: true).select do |message|
        next false unless Message.where(id: message.id, inquiry_alert_attempted_at: nil)
          .update_all(inquiry_alert_attempted_at: Time.current) == 1

        Leads::UnlinkedInquiries.resolve_message!(message) == :safety_net_lead
      end
    end
    return if messages.empty?

    InquirySafetyNetMailer.unlinked(messages).deliver_now
  end
end
