# Queues the automatic "Your trip match" email for a trip quiz inquiry
# (TripQuizEmail). Runs from the lead's trip_quiz_email notification, about a
# minute after intake, so it queues before the automatic first reply checks
# for earlier outbound mail.
class TripQuizEmailJob < ApplicationJob
  queue_as :default
  discard_on ActiveRecord::RecordNotFound

  def perform(lead_id)
    lead = Lead.find(lead_id)
    email = lead.email.to_s.strip.downcase
    message = nil
    # SQLite serializes writers; the per-inquiry reservation and the message
    # commit together, so a retry can only re-enqueue that one message.
    TripQuizEmail.transaction do
      existing = TripQuizEmail.find_by(lead_id: lead.id)
      if existing
        message = existing.message
        next
      end
      reason = TripQuizEmail.skip_reason(lead, email: email)
      if reason
        TripQuizEmail.log(lead, "skipped (#{reason})")
        next
      end
      reservation = TripQuizEmail.create!(lead: lead, email: email)
      message = Outbound::Composer.call(owner: lead,
        params: TripQuizEmail.content_for(lead).merge(to: email, automatic_email: true))
      raise ActiveRecord::RecordInvalid, message unless message.to_list == [ email ]
      reservation.update!(message: message)
      TripQuizEmail.log(lead, "queued", message: message)
    end
    OutboundDeliveryJob.perform_later(message.id) if message&.status == "queued"
  rescue ActiveRecord::RecordInvalid, Outbound::Uploads::SensitiveDocument => error
    TripQuizEmail.log(lead, "skipped (sending gate: #{error.message.truncate(200)})")
  end
end
