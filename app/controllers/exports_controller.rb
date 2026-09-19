require "csv"

class ExportsController < ApplicationController
  def show
    send_data export_zip, filename: "perfectcrm-export-#{Time.zone.today.iso8601}.zip",
      type: "application/zip", disposition: "attachment"
  end

  private

  def export_zip
    buffer = Zip::OutputStream.write_buffer do |zip|
      zip.put_next_entry("leads.csv")
      zip.write(bom + LeadExport.to_csv)
      zip.put_next_entry("clients.csv")
      zip.write(bom + ClientExport.to_csv)
      zip.put_next_entry("people.csv")
      zip.write(bom + PersonExport.to_csv)
      zip.put_next_entry("organizations.csv")
      zip.write(bom + OrganizationExport.to_csv)
      zip.put_next_entry("notes.csv")
      zip.write(bom + NoteExport.to_csv)
      zip.put_next_entry("tags.csv")
      zip.write(bom + TagExport.to_csv)
      zip.put_next_entry("taggings.csv")
      zip.write(bom + TaggingExport.to_csv)
      zip.put_next_entry("activity_events.csv")
      zip.write(bom + ActivityEventExport.to_csv)
    end
    buffer.string
  end

  def bom
    "\uFEFF"
  end
end

module ClientExport
  def self.to_csv
    ExportCSV.generate do |csv|
      csv << %w[id name email phone country state kind source campaign_name referral_code referred_by_organization perfectbook_contact_id pipeline_stage archived_at notes_count last_activity_at created_at updated_at]
      Client.ordered.includes(:referred_by_organization).find_each do |client|
        csv << [
          client.id, client.name, client.email, client.phone,
          client.country, client.state, client.kind, client.source, client.campaign_name,
          client.referral_code,
          client.referred_by_organization&.name, client.perfectbook_contact_id,
          client.pipeline_stage, client.archived_at&.iso8601, client.notes_count,
          client.last_activity_at&.iso8601, client.created_at.iso8601, client.updated_at.iso8601
        ]
      end
    end
  end
end

module PersonExport
  def self.to_csv
    ExportCSV.generate do |csv|
      csv << %w[id client_id client_name lead_id lead_name name email phone role created_at updated_at]
      Person.includes(:client, :lead).order(:id).find_each do |person|
        csv << [
          person.id, person.client_id, person.client&.name,
          person.lead_id, person.lead&.name,
          person.name, person.email, person.phone, person.role,
          person.created_at.iso8601, person.updated_at.iso8601
        ]
      end
    end
  end
end

module LeadExport
  def self.to_csv
    ExportCSV.generate do |csv|
      csv << %w[id name email phone country state kind source campaign_name referral_code external_ref fit_score fit_band fit_reason status trip_interest expected_value_minor lost_reason lost_note stage_changed_at last_touch_at converted_client_id converted_at archived_at referred_by_organization perfectbook_contact_id notes_count last_activity_at created_at updated_at phone_raw trip_handle trip_title message consent_contact_at consent_text_version placement travel_month travel_year timing_unknown party_size budget_band metadata spam_score received_at reference]
      Lead.ordered.includes(:referred_by_organization).find_each do |lead|
        csv << [
          lead.id, lead.name, lead.email, lead.phone,
          lead.country, lead.state, lead.kind, lead.source, lead.campaign_name, lead.referral_code, lead.external_ref,
          lead.fit_score, lead.fit_band, lead.fit_reason, lead.status,
          lead.trip_interest, lead.expected_value_minor, lead.lost_reason, lead.lost_note,
          lead.stage_changed_at&.iso8601, lead.last_touch_at&.iso8601,
          lead.converted_client_id, lead.converted_at&.iso8601, lead.archived_at&.iso8601,
          lead.referred_by_organization&.name, lead.perfectbook_contact_id,
          lead.notes_count, lead.last_activity_at&.iso8601,
          lead.created_at.iso8601, lead.updated_at.iso8601,
          lead.phone_raw, lead.trip_handle, lead.trip_title, lead.message,
          lead.consent_contact_at&.iso8601, lead.consent_text_version, lead.placement,
          lead.travel_month, lead.travel_year, lead.timing_unknown, lead.party_size,
          lead.budget_band, lead.metadata.to_json, lead.spam_score,
          lead.received_at&.iso8601, lead.reference
        ]
      end
    end
  end
end

module OrganizationExport
  def self.to_csv
    ExportCSV.generate do |csv|
      csv << %w[id name kind email phone country website perfectbook_contact_id last_activity_at created_at updated_at]
      Organization.ordered.find_each do |organization|
        csv << [
          organization.id, organization.name, organization.kind, organization.email, organization.phone,
          organization.country, organization.website, organization.perfectbook_contact_id,
          organization.last_activity_at&.iso8601, organization.created_at.iso8601, organization.updated_at.iso8601
        ]
      end
    end
  end
end

module NoteExport
  def self.to_csv
    ExportCSV.generate do |csv|
      csv << %w[id notable_type notable_id notable_name body author_email created_at]
      Note.includes(:author).order(:id).find_each do |note|
        csv << [
          note.id, note.notable_type, note.notable_id, notable_name(note),
          note.body, note.author&.email, note.created_at.iso8601
        ]
      end
    end
  end

  def self.notable_name(note)
    note.notable.try(:name)
  rescue NoMethodError, ActiveRecord::RecordNotFound
    nil
  end
end

module ExportCSV
  def self.generate(&block)
    CSV.generate(write_converters: ->(value) { value.to_s.match?(/\A[=+@-]/) ? "'#{value}" : value }, &block)
  end
end

module TagExport
  def self.to_csv
    ExportCSV.generate do |csv|
      csv << %w[id name]
      Tag.find_each { |tag| csv << [ tag.id, tag.name ] }
    end
  end
end

module TaggingExport
  def self.to_csv
    ExportCSV.generate do |csv|
      csv << %w[id tag_id taggable_type taggable_id]
      Tagging.find_each { |tagging| csv << [ tagging.id, tagging.tag_id, tagging.taggable_type, tagging.taggable_id ] }
    end
  end
end

module ActivityEventExport
  def self.to_csv
    ExportCSV.generate do |csv|
      csv << %w[id subject_type subject_id kind summary occurred_at metadata created_at updated_at]
      ActivityEvent.find_each do |event|
        csv << [ event.id, event.subject_type, event.subject_id, event.kind, event.summary,
          event.occurred_at.iso8601, event.metadata.to_json, event.created_at.iso8601, event.updated_at.iso8601 ]
      end
    end
  end
end
