class ReplyAlertJob < ApplicationJob
  queue_as :default
  discard_on ActiveRecord::RecordNotFound

  def self.enqueue_pending
    Message.where(reply_alert_state: "pending").find_each { |message| perform_later(message.id) }
  end

  def perform(message_id)
    message = Message.find(message_id)
    # A permanent claim before SMTP means retries never send another alert,
    # even when SMTP accepted it but its acknowledgement was lost.
    claimed = Message.transaction do
      next false unless Message.where(id: message.id, reply_alert_state: "pending")
        .update_all(reply_alert_state: "sending") == 1
      if ReplyAlertReservation.exists?(provider_message_id: message.provider_message_id)
        message.update!(reply_alert_state: "duplicate")
        next false
      end
      ReplyAlertReservation.create!(provider_message_id: message.provider_message_id, message: message)
      true
    end
    return unless claimed

    ReplyAlertMailer.reply_received(message).deliver_now
    message.update!(reply_alert_state: "sent")
  rescue StandardError => error
    message&.update!(reply_alert_state: "failed") if claimed
    raise error
  end
end
