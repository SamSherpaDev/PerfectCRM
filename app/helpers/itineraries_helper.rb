# Lead page labels for itinerary designer inquiries (records/_itinerary and
# the Details card's free-call row). Wording rules: Leads::Itinerary.
module ItinerariesHelper
  # "Weekday mornings, their time (America/New York)" or "As soon as possible (America/Los Angeles)"
  def call_request_label(call_request)
    window = ::Leads::Itinerary.call_window_label(call_request["window"])
    zone = call_request["timezone"].presence
    if window
      zone ? "#{window}, their time (#{zone.tr('_', ' ')})" : "#{window}, their time"
    else
      zone ? "As soon as possible (#{zone.tr('_', ' ')})" : "As soon as possible"
    end
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
