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
    end
    buffer.string
  end

  def bom
    "\uFEFF"
  end
end

module ClientExport
  def self.to_csv
    CSV.generate do |csv|
      csv << %w[id name email phone country state kind source referred_by_organization perfectbook_contact_id archived_at notes_count last_activity_at created_at updated_at]
      Client.ordered.includes(:referred_by_organization).find_each do |client|
        csv << [
          client.id, client.name, client.email, client.phone,
          client.country, client.state, client.kind, client.source,
          client.referred_by_organization&.name, client.perfectbook_contact_id,
          client.archived_at&.iso8601, client.notes_count,
          client.last_activity_at&.iso8601, client.created_at.iso8601, client.updated_at.iso8601
        ]
      end
    end
  end
end

module PersonExport
  def self.to_csv
    CSV.generate do |csv|
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
    CSV.generate do |csv|
      csv << %w[id name email phone country state kind source campaign_name external_ref fit_score fit_band fit_reason status converted_client_id converted_at referred_by_organization perfectbook_contact_id notes_count last_activity_at created_at updated_at]
      Lead.ordered.includes(:referred_by_organization).find_each do |lead|
        csv << [
          lead.id, lead.name, lead.email, lead.phone,
          lead.country, lead.state, lead.kind, lead.source, lead.campaign_name, lead.external_ref,
          lead.fit_score, lead.fit_band, lead.fit_reason, lead.status,
          lead.converted_client_id, lead.converted_at&.iso8601,
          lead.referred_by_organization&.name, lead.perfectbook_contact_id,
          lead.notes_count, lead.last_activity_at&.iso8601,
          lead.created_at.iso8601, lead.updated_at.iso8601
        ]
      end
    end
  end
end

module OrganizationExport
  def self.to_csv
    CSV.generate do |csv|
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
    CSV.generate do |csv|
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
