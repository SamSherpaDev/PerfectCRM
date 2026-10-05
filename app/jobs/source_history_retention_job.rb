# Source-only retention. Does not delete CRM contacts, correspondence, or any
# PerfectBook records. Contact/document deletion stays in its separate policy.
class SourceHistoryRetentionJob < ApplicationJob
  queue_as :default

  def perform(now: Time.current)
    Lead.find_each do |lead|
      lead.with_lock do
        metadata = (lead.metadata || {}).deep_dup
        received = lead.received_at || lead.created_at
        if received <= now - 180.days
          metadata.delete("attribution")
          if metadata["acquisition"].is_a?(Hash)
            Leads::Acquisition::TOUCHES.each do |key|
              touch = metadata["acquisition"][key]
              touch.except!(*Leads::Acquisition::CLICK_KEYS, "landing_url", "referrer_host") if touch.is_a?(Hash)
            end
            metadata["acquisition"].delete("submission_page")
          end
          metadata.delete("page")
          lead.update_columns(metadata: metadata)
        end
        if expired?(lead, now)
          metadata.except!("acquisition", "attribution", "page")
          lead.update_columns(metadata: metadata)
          purge_source(lead)
          lead.people.each { |person| purge_source(person) }
        end
      end
    end
    Client.find_each do |client|
      next unless expired?(client, now)
      client.with_lock do
        purge_source(client)
        client.people.each { |person| purge_source(person) }
      end
    end
  end

  private

  def expired?(record, now)
    client = record.is_a?(Client) ? record : record.converted_client
    if client
      bookings = PerfectBook::Booking.where(perfectbook_contact_id: client.perfectbook_contact_id) if client.perfectbook_contact_id
      last_booking = [ bookings&.maximum(:end_date), bookings&.maximum(:start_date) ].compact.max
      # Recording a note or editing source must not restart the lifetime clock.
      # Until a complete mirror exists, creation uses the conservative booked
      # horizon, explicitly not an asserted financial receipt date.
      baseline = last_booking&.in_time_zone || client.created_at
      baseline <= now - 7.years
    else
      # A returning inquiry is still a separate unbooked ask until conversion.
      last_contact = record.last_touch_at || record.received_at || record.created_at
      last_contact <= now - 24.months
    end
  end

  def purge_source(record)
    expired_fields = { reported_source_code: nil, reported_source_detail: nil,
      source_answer_state: "not_asked", source_confirmed_at: nil, capture_channel: nil,
      referred_by_client_id: nil, referred_by_person_id: nil, origin_lead_id: nil }
    if record.is_a?(Person)
      expired_fields[:origin_person_id] = nil
    else
      expired_fields.merge!(source: record.is_a?(Lead) ? "manual" : nil, campaign_name: nil,
        referral_code: nil, referred_by_organization_id: nil)
    end
    record.update_columns(expired_fields)
    # Deliberate retention exception to ordinary append-only sales history.
    events = ActivityEvent.where(kind: %w[source_answer source_referral call])
    provenance = record.is_a?(Person) ? "from_person_id" : "from_lead_id"
    if record.is_a?(Lead) || record.is_a?(Person)
      events.where("json_extract(metadata, '$.#{provenance}') = ?", record.id).delete_all
    end
    record.activity_events.where(kind: %w[source_answer source_referral call]).delete_all
    conversions = record.activity_events.where(kind: "conversion")
    if record.is_a?(Lead)
      conversions = conversions.or(ActivityEvent.where(kind: "conversion").where(
        "json_extract(metadata, '$.lead_id') = ? OR json_extract(metadata, '$.from_lead_id') = ?", record.id, record.id))
    elsif record.is_a?(Person)
      conversions = conversions.or(ActivityEvent.where(kind: "conversion").where(
        "json_extract(metadata, '$.from_person_id') = ?", record.id))
    end
    conversions.find_each do |event|
      summary = event.summary.start_with?("Returned as a lead from ") ? "Returned as a lead" : event.summary
      conversions.where(id: event.id).update_all(metadata: (event.metadata || {}).except("source", "campaign"), summary: summary)
    end
  end
end
