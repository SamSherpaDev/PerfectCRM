# Queues the automatic "Your trip match" email for a trip quiz inquiry
# (TripQuizEmail). Runs from the lead's trip_quiz_email notification, about a
# minute after intake. When the email is skipped, it schedules the lead's
# general automatic first reply notification two minutes after intake, so a
# quiz visitor gets exactly one automatic email.
class TripQuizEmailJob < ApplicationJob
  queue_as :default
  discard_on ActiveRecord::RecordNotFound

  def perform(lead_id)
    lead = Lead.find(lead_id)
    reservation = reserve(lead)
    if reservation
      message = reservation.message
      OutboundDeliveryJob.perform_later(message.id) if message&.status == "queued"
    else
      lead.lead_notifications.find_or_create_by!(event: "auto_first_reply") { |row| row.available_at = lead.created_at + 2.minutes }
      LeadNotification.enqueue_pending(lead.id)
    end
  end

  private

  # The lead's reservation with its queued message, or nil when skipped.
  def reserve(lead)
    email = lead.email.to_s.strip.downcase
    # SQLite serializes writers; the per-inquiry reservation and the message
    # commit together, so a retry can only re-enqueue that one message.
    TripQuizEmail.transaction do
      existing = TripQuizEmail.find_by(lead_id: lead.id)
      next existing if existing

      reason = TripQuizEmail.skip_reason(lead, email: email)
      if reason
        TripQuizEmail.log(lead, "skipped (#{reason})")
        next nil
      end
      reservation = TripQuizEmail.create!(lead: lead, email: email)
      message = Outbound::Composer.call(owner: lead,
        params: TripQuizEmail.content_for(lead).merge(to: email, automatic_email: true))
      raise ActiveRecord::RecordInvalid, message unless message.to_list == [ email ]
      reservation.update!(message: message)
      TripQuizEmail.log(lead, "queued", message: message)
      reservation
    end
  rescue ActiveRecord::RecordInvalid, Outbound::Uploads::SensitiveDocument => error
    TripQuizEmail.log(lead, "skipped (sending gate: #{error.message.truncate(200)})")
    nil
  end
end
