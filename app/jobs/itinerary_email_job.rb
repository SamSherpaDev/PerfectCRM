# Queues the automatic "Your Nepal itinerary" email for an itinerary designer
# inquiry (ItineraryEmail). Runs from the lead's itinerary_email notification,
# about a minute after intake, so it queues before the automatic first reply
# checks for earlier outbound mail.
class ItineraryEmailJob < ApplicationJob
  queue_as :default
  discard_on ActiveRecord::RecordNotFound

  def perform(lead_id)
    lead = Lead.find(lead_id)
    email = lead.email.to_s.strip.downcase
    message = nil
    # SQLite serializes writers; the per-inquiry reservation and the message
    # commit together, so a retry can only re-enqueue that one message.
    ItineraryEmail.transaction do
      existing = ItineraryEmail.find_by(lead_id: lead.id)
      if existing
        message = existing.message
        next
      end
      reason = ItineraryEmail.skip_reason(lead, email: email)
      if reason
        ItineraryEmail.log(lead, "skipped (#{reason})")
        next
      end
      reservation = ItineraryEmail.create!(lead: lead, email: email)
      message = Outbound::Composer.call(owner: lead,
        params: ItineraryEmail.content_for(lead).merge(to: email, automatic_email: true))
      raise ActiveRecord::RecordInvalid, message unless message.to_list == [ email ]
      reservation.update!(message: message)
      ItineraryEmail.log(lead, "queued", message: message)
    end
    OutboundDeliveryJob.perform_later(message.id) if message&.status == "queued"
  rescue ActiveRecord::RecordInvalid, Outbound::Uploads::SensitiveDocument => error
    ItineraryEmail.log(lead, "skipped (sending gate: #{error.message.truncate(200)})")
  end
end
