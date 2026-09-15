# Polls booking + invoice status every 15 minutes for mirrored contacts.
#
# NOTE: when the sibling Client/Organization models land with their
# perfectbook_contact_id column, scope this to contacts that have a local
# CRM record. Until then, sync bookings for all mirrored customer contacts.
#
# TODO: record an ActivityEvent when a mirrored booking's status or invoice
# badge changes, once that model exists on main.
module PerfectBook
  class SyncBookingsJob < ApplicationJob
    queue_as :default

    def perform(client: nil)
      client ||= Client.new
      contacts = Contact.where(kind: "customer")
      contacts.find_each do |mirror|
        sync_one_contact!(client, mirror)
      end
      SyncState.record_success!("bookings")
    rescue PerfectBook::Error => e
      SyncState.record_error!("bookings", e.message)
      raise if e.is_a?(RateLimitedError) || e.is_a?(UnavailableError)
    end

    private

    def sync_one_contact!(client, mirror)
      result = client.list_contact_bookings(mirror.perfectbook_id)
      return if result[:not_modified]

      now = Time.current
      seen_ids = []
      result[:data].each do |booking|
        seen_ids << booking.id
        Booking.find_or_initialize_by(perfectbook_id: booking.id).update!(
          perfectbook_contact_id: mirror.perfectbook_id, ref: booking.ref, status: booking.status,
          trip_id: booking.trip_id, trip_name: booking.trip_name,
          departure_id: booking.departure_id, departure_place: booking.departure_place,
          start_date: parse_date(booking.start_date), end_date: parse_date(booking.end_date),
          party_size: booking.party_size, price_per_person_minor: booking.price_per_person_minor,
          total_minor: booking.total_minor, paid_minor: booking.paid_minor,
          balance_due_minor: booking.balance_due_minor, currency: booking.currency,
          invoice_badge: booking.invoice_badge, invoice_number: booking.invoice_number,
          payment_reference: booking.payment_reference, deep_link: booking.deep_link,
          synced_at: now
        )
      end
      # Cancelled-away bookings vanish from nothing: the API is the full
      # list, so drop local rows the server no longer returns for this contact.
      Booking.where(perfectbook_contact_id: mirror.perfectbook_id)
        .where.not(perfectbook_id: seen_ids).delete_all if seen_ids.any?
    end

    def parse_date(value)
      return nil if value.blank?

      Date.iso8601(value.to_s)
    rescue Date::Error, ArgumentError
      nil
    end
  end
end
