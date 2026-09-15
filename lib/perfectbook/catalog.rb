# Quote-builder source: active trips with their upcoming departures.
# Reads the local PerfectBook mirror (never hits the API directly); the
# sync jobs in app/jobs/perfectbook/ keep the mirror fresh.
module PerfectBook
  class Catalog
    def initialize(today: Date.current)
      @today = today
    end

    def active_trips
      PerfectBook::Trip.where(active: true).order(:name)
    end

    def upcoming_departures(limit: 50)
      PerfectBook::Departure
        .where("start_date IS NULL OR date(start_date) >= ?", @today.iso8601)
        .order(Arel.sql("start_date IS NULL, start_date ASC"))
        .limit(limit)
    end

    def departures_for_trip(trip_id)
      PerfectBook::Departure
        .where(perfectbook_trip_id: trip_id)
        .where("start_date IS NULL OR date(start_date) >= ?", @today.iso8601)
        .order(Arel.sql("start_date IS NULL, start_date ASC"))
    end

    def available_departures(limit: 50)
      upcoming_departures(limit: limit).select do |departure|
        departure.available_seats.nil? || departure.available_seats.to_i.positive?
      end
    end
  end
end
