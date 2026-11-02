# Lead page labels for itinerary designer inquiries (records/_itinerary and
# the Details card's free-call row). Wording rules: Leads::Itinerary.
module ItinerariesHelper
  # The automatic "Your Nepal itinerary" email for this inquiry, as
  # { word:, tone:, detail: } for a badge plus a muted line.
  def itinerary_email_state(lead)
    message = lead.itinerary_email&.message
    if message
      case message.status
      when "sent"
        { word: "Sent", tone: :success, detail: itinerary_moment(message.sent_at) }
      when "failed"
        { word: "Not sent", tone: :danger, detail: message.send_error.presence }
      else
        { word: "Sending", tone: :info, detail: "Queued #{itinerary_moment(message.created_at)}" }
      end
    elsif (skipped = lead.activity_events.where(kind: "automation").where("summary LIKE ?", "Itinerary email: skipped%").order(occurred_at: :desc).first)
      { word: "Not sent", tone: :neutral, detail: skipped.summary.delete_prefix("Itinerary email: skipped").strip.delete_prefix("(").delete_suffix(")").upcase_first }
    elsif lead.lead_notifications.where(event: "itinerary_email", delivered_at: nil).exists?
      { word: "Waiting", tone: :info, detail: "Sends about a minute after the inquiry arrived." }
    else
      { word: "Off", tone: :neutral, detail: "The itinerary email was off when this arrived." }
    end
  end

  # "Weekday mornings, their time (America/New_York)"
  def call_request_label(call_request)
    window = ::Leads::Itinerary.call_window_label(call_request["window"])
    zone = call_request["timezone"].presence
    zone ? "#{window}, their time (#{zone.tr('_', ' ')})" : "#{window}, their time"
  end

  # "Nov 2, 2026 15:00": these pages are read days later, so always dated.
  def itinerary_moment(time)
    "#{date_short(time)} #{time_24_12(time)}"
  end

  def call_requested_at(call_request)
    Time.iso8601(call_request["requested_at"].to_s).in_time_zone
  rescue ArgumentError
    nil
  end
end
