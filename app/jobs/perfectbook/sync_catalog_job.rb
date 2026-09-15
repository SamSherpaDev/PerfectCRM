# Polls the trip + departure catalog every 15 minutes into the local
# mirror. ETag 304 on the first page means nothing changed: no-op.
module PerfectBook
  class SyncCatalogJob < ApplicationJob
    queue_as :default

    def perform(client: nil)
      client ||= Client.new
      sync_trips(client)
      sync_departures(client)
      SyncState.record_success!("catalog")
    rescue PerfectBook::Error => e
      SyncState.record_error!("catalog", e.message)
      raise if retryable?(e)
    end

    private

    def retryable?(error)
      error.is_a?(RateLimitedError) || error.is_a?(UnavailableError)
    end

    def sync_trips(client)
      result = client.list_trips
      return if result[:not_modified]

      now = Time.current
      result[:data].each do |trip|
        Trip.find_or_initialize_by(perfectbook_id: trip.id).update!(
          name: trip.name, active: trip.active, status: trip.status,
          shopify_product_id: trip.shopify_product_id,
          departures_count: trip.departures_count, departure_ids: trip.departure_ids,
          first_start_date: parse_date(trip.first_start_date),
          last_end_date: parse_date(trip.last_end_date),
          pb_created_at: parse_time(trip.created_at), pb_updated_at: parse_time(trip.updated_at),
          synced_at: now
        )
      end
      result[:commit_etags]&.call
    end

    def sync_departures(client)
      result = client.list_departures
      return if result[:not_modified]

      now = Time.current
      result[:data].each do |dep|
        Departure.find_or_initialize_by(perfectbook_id: dep.id).update!(
          perfectbook_trip_id: dep.trip_id, trip_name: dep.trip_name, label: dep.label,
          start_date: parse_date(dep.start_date), end_date: parse_date(dep.end_date),
          duration_days: dep.duration_days, place: dep.place, country_codes: dep.country_codes,
          status: dep.status, seats: dep.seats, booked_seats: dep.booked_seats,
          available_seats: dep.available_seats, price_per_person_minor: dep.price_per_person_minor,
          currency: dep.currency, pb_created_at: parse_time(dep.created_at),
          pb_updated_at: parse_time(dep.updated_at), synced_at: now
        )
      end
      result[:commit_etags]&.call
    end

    def parse_date(value)
      return nil if value.blank?

      Date.iso8601(value.to_s)
    rescue Date::Error, ArgumentError
      nil
    end

    def parse_time(value)
      return nil if value.blank?

      Time.iso8601(value.to_s)
    rescue ArgumentError
      nil
    end
  end
end
