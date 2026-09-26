# Polls booking + invoice status every 15 minutes for mirrored contacts.
#
# The full sweep covers every mirrored customer contact. The Refresh button
# on a client or lead page calls the same job with perfectbook_contact_id
# to re-pull just that contact.
module PerfectBook
  class SyncBookingsJob < ApplicationJob
    queue_as :default

    def perform(client: nil, perfectbook_contact_id: nil)
      client ||= Client.new(pace_requests: true)
      if perfectbook_contact_id.present?
        mirror = Contact.find_by(perfectbook_id: perfectbook_contact_id)
        sync_one_contact!(client, mirror) if mirror
        SyncState.record_success!("bookings")
        return
      end
      state = SyncState.for("bookings")
      contacts = Contact.where(kind: "customer").where("id > ?", state.contact_cursor || 0)
      contacts.find_each do |mirror|
        sync_one_contact!(client, mirror)
        state.update!(contact_cursor: mirror.id)
      end
      state.update!(contact_cursor: nil)
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
        Booking.transaction(requires_new: true) do
          booking_mirror = Booking.find_or_initialize_by(perfectbook_id: booking.id)
          booking_mirror.assign_attributes(
            perfectbook_contact_id: mirror.perfectbook_id, ref: booking.ref, status: booking.status,
            trip_id: booking.trip_id, trip_name: booking.trip_name,
            departure_id: booking.departure_id, departure_place: booking.departure_place,
            start_date: parse_date(booking.start_date), end_date: parse_date(booking.end_date),
            party_size: booking.party_size, price_per_person_minor: booking.price_per_person_minor,
            total_minor: booking.total_minor, paid_minor: booking.paid_minor,
            balance_due_minor: booking.balance_due_minor, currency: booking.currency,
            invoice_badge: booking.invoice_badge, invoice_number: booking.invoice_number,
            payment_reference: booking.payment_reference, deep_link: booking.deep_link,
            documents_json: booking.documents.presence || {}, missing_count: booking.missing_count.to_i,
            checklist_json: booking.checklist.presence || [],
            synced_at: now
          )
          # First sync that saw money paid: the weekly report's deposit date.
          booking_mirror.deposit_seen_at ||= now if booking_mirror.paid_minor.to_i.positive?
          booking_mirror.save!
          DemoRecord.where(record_type: Booking.name, record_id: booking_mirror.id).delete_all
        end
      end
      # A successful response is the full list, even when empty. Only a
      # first-page 304 above preserves all existing rows for this contact.
      Booking.where(perfectbook_contact_id: mirror.perfectbook_id)
        .where.not(perfectbook_id: seen_ids).delete_all
      result[:commit_etags]&.call
    end

    def parse_date(value)
      return nil if value.blank?

      Date.iso8601(value.to_s)
    rescue Date::Error, ArgumentError
      nil
    end
  end
end
