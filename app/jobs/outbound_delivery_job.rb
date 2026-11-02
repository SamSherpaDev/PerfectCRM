# Delivers a persisted outbound Message on Solid Queue.
# Delivery and draft retention: see README.md, "Replying".
require "net/smtp"

class OutboundDeliveryJob < ApplicationJob
  queue_as :default

  # SMTP and connection errors retry with backoff; errors outside this
  # list fail immediately into the failed state.
  TRANSIENT_ERRORS = [
    Net::SMTPError, SocketError, IOError, Timeout::Error,
    OpenSSL::SSL::SSLError, Errno::ECONNRESET, Errno::EPIPE, Errno::ETIMEDOUT
  ].freeze
  MAX_ATTEMPTS = 5

  discard_on ActiveRecord::RecordNotFound
  discard_on ActiveJob::DeserializationError

  def perform(message_id)
    message = Message.find(message_id)
    return unless message.status == "queued"

    # Automatic mail (first reply, itinerary email) gets one SMTP attempt.
    automatic = AutomaticFirstReply.find_by(message_id: message.id) || ItineraryEmail.find_by(message_id: message.id)
    label = automatic.is_a?(ItineraryEmail) ? "Itinerary email" : "Automatic first reply"
    return if automatic && !automatic.delivery_allowed?

    claimed = Message.transaction do
      next false unless message.mark_sending!
      if automatic && !automatic.claim_delivery!
        message.mark_failed!("#{label} already attempted; send any further correspondence manually.")
        next false
      end
      true
    end
    return unless claimed
    ClientMailer.outbound(message).deliver_now
    message.mark_sent!
    automatic.class.log(automatic.lead, "sent", message: message) if automatic&.lead
    message.group_send&.refresh_status!
  rescue *TRANSIENT_ERRORS => e
    raise unless claimed

    if automatic
      message.mark_failed!(e.message)
      automatic.class.log(automatic.lead, "failed (delivery uncertain; not retried)", message: message) if automatic.lead
    elsif executions < MAX_ATTEMPTS
      message.update!(status: "queued", send_error: e.message.truncate(500))
      retry_job(wait: backoff)
    else
      message.mark_failed!(e.message)
      message.group_send&.refresh_status!
    end
  rescue StandardError => e
    raise unless claimed

    message.mark_failed!(e.message) unless message.sent?
    automatic.class.log(automatic.lead, "failed (#{e.class})", message: message) if automatic&.lead
    message.group_send&.refresh_status!
  end

  private

  def backoff
    (executions**2).minutes
  end
end
