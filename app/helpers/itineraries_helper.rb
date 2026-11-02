# Lead page labels for itinerary designer inquiries (records/_itinerary and
# the Details card's free-call row). Wording rules: Leads::Itinerary.
module ItinerariesHelper
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
