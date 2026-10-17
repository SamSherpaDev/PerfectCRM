class InquirySafetyNetJob < ApplicationJob
  queue_as :default

  def perform
    # Reserve before SMTP, just like reply alerts. Even an uncertain SMTP
    # acknowledgement must never cause a second alert about the same message.
    messages = Message.transaction do
      Leads::UnlinkedInquiries.new.messages(unalerted: true).select do |message|
        Message.where(id: message.id, inquiry_alert_attempted_at: nil)
          .update_all(inquiry_alert_attempted_at: Time.current) == 1
      end
    end
    return if messages.empty?

    InquirySafetyNetMailer.unlinked(messages).deliver_now
  end
end
