# Polls PerfectBook contacts every 15 minutes using updated_since from
# the last success, so each run only transfers changed rows.
module PerfectBook
  class SyncContactsJob < ApplicationJob
    queue_as :default

    def perform(client: nil)
      client ||= Client.new
      since = SyncState.for("contacts").last_success_at
      result = client.list_contacts(updated_since: since)
      unless result[:not_modified]
        now = Time.current
        result[:data].each { |contact| upsert_contact!(contact, now) }
      end
      SyncState.record_success!("contacts")
    rescue PerfectBook::Error => e
      SyncState.record_error!("contacts", e.message)
      raise if e.is_a?(RateLimitedError) || e.is_a?(UnavailableError)
    end

    private

    def upsert_contact!(contact, now)
      Contact.find_or_initialize_by(perfectbook_id: contact.id).update!(
        kind: contact.kind, name: contact.name, email: contact.email, phone: contact.phone,
        country: contact.country, state: contact.state, archived: contact.archived,
        pb_created_at: parse_time(contact.created_at), pb_updated_at: parse_time(contact.updated_at),
        synced_at: now
      )
    end

    def parse_time(value)
      return nil if value.blank?

      Time.iso8601(value.to_s)
    rescue ArgumentError
      nil
    end
  end
end
