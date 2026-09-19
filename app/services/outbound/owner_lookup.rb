# frozen_string_literal: true

# Finds the CRM record a recipient email belongs to: a client first (own
# email, then a person's), then an open lead. Strangers return nil — the
# CRM never auto-creates records for unknown senders.
module Outbound
  module OwnerLookup
    def self.for_email(email)
      normalized = email.to_s.strip.downcase
      return nil if normalized.blank?

      client = Client.find_by(email: normalized) ||
        Person.where("lower(email) = ?", normalized).where.not(client_id: nil).first&.client
      return client if client

      Lead.open.find_by(email: normalized) ||
        Person.where("lower(email) = ?", normalized).where.not(lead_id: nil).first&.lead ||
        Client.where("EXISTS (SELECT 1 FROM json_each(ambiguous_emails) WHERE value = ?)", normalized).first ||
        Lead.open.where("EXISTS (SELECT 1 FROM json_each(ambiguous_emails) WHERE value = ?)", normalized).first
    end
  end
end
