# Delivers one outbound Message on Solid Queue with retries. The timeline
# shows queued → sending → sent; a failure marks the message failed but
# keeps the conversation draft, so the captain's words are never lost.
# A failed message can be retried from the timeline (Messages#retry).
require "net/smtp"

class OutboundDeliveryJob < ApplicationJob
  queue_as :default

  # Transient transport failures retry with backoff; anything else
  # (bad address, oversized attachment) fails fast into the failed state.
  TRANSIENT_ERRORS = [
    Net::SMTPError, SocketError, IOError, Timeout::Error,
    OpenSSL::SSL::SSLError, Errno::ECONNRESET, Errno::EPIPE, Errno::ETIMEDOUT
  ].freeze
  MAX_ATTEMPTS = 5

  discard_on ActiveRecord::RecordNotFound
  discard_on ActiveJob::DeserializationError

  def perform(message_id)
    message = Message.find(message_id)
    claimed = message.mark_sending!
    return unless claimed
    ClientMailer.outbound(message).deliver_now
    message.mark_sent!
    message.group_send&.refresh_status!
  rescue *TRANSIENT_ERRORS => e
    raise unless claimed

    if executions < MAX_ATTEMPTS
      message.update!(status: "queued", send_error: e.message.truncate(500))
      retry_job(wait: backoff)
    else
      message.mark_failed!(e.message)
      message.group_send&.refresh_status!
    end
  rescue StandardError => e
    raise unless claimed

    message.mark_failed!(e.message) unless message.sent?
    message.group_send&.refresh_status!
  end

  private

  def backoff
    (executions**2).minutes
  end
end
