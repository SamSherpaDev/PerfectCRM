module Leads
  # Explicit inquiry relationships only: never match a global email, and never
  # give the booker's number to a companion. Column writes intentionally bypass
  # converted inquiries' read-only validation; Active Record still encrypts them.
  class PhoneBackfill
    def self.call
      new.call
    end

    def call
      counts = { leads_updated: 0, clients_updated: 0, people_updated: 0, unparseable: 0 }
      Lead.order(:id).find_each do |lead|
        lead.with_lock do
          number = Phone.normalize(lead.phone_raw, country: lead.country)
          counts[:unparseable] += 1 if lead.phone.blank? && lead.phone_raw.present? && number.nil?
          if lead.phone.blank? && number
            lead.update_columns(phone: number)
            lead.sync_fts!
            counts[:leads_updated] += 1
          end
          number = lead.phone.presence || number
          client = lead.converted_client
          if client
            client.with_lock do
              if client.phone.blank?
                raw = client.phone_raw.presence || lead.phone_raw.presence
                client_number = Phone.normalize(raw, country: client.country)
                updates = {}
                updates[:phone] = client_number if client_number
                updates[:phone_raw] = raw if client.phone_raw.blank? && raw
                if updates.any?
                  client.update_columns(updates)
                  client.sync_fts!
                  counts[:clients_updated] += 1
                end
              end
            end
          end
          next if number.blank? || lead.email.blank?

          people = lead.people.where(email: lead.email).to_a
          people += client.people.where(email: lead.email).to_a if client
          people.each do |person|
            person.with_lock do
              next if person.phone.present?

              person.update_columns(phone: number)
              person.owner.sync_fts!
              counts[:people_updated] += 1
            end
          end
        end
      end
      counts
    end
  end
end
