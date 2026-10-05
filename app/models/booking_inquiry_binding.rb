require "digest"

# One primary inquiry per PerfectBook booking, independent of the mirror's lifecycle.
class BookingInquiryBinding < ApplicationRecord
  belongs_to :lead
  validates :perfectbook_id, presence: true, uniqueness: true
  validates :state, inclusion: { in: %w[explicit inferred reviewed] }
  validates :actor, :evidence, :linked_at, :upstream_fingerprint, presence: true

  def self.link!(booking, lead:, actor:, evidence:, state: "reviewed", reason: nil)
    booking.with_lock do
      lead.reload
      contact_ids = [ lead.perfectbook_contact_id, lead.converted_client&.perfectbook_contact_id, lead.existing_client&.perfectbook_contact_id ].compact
      raise ArgumentError, "Choose an inquiry for this PerfectBook contact" unless contact_ids.include?(booking.perfectbook_contact_id)
      binding = find_or_initialize_by(perfectbook_id: booking.perfectbook_id)
      prior = binding.persisted? ? binding.attributes.slice("lead_id", "state", "evidence") : nil
      fingerprint = upstream_fingerprint(booking)
      if binding.persisted? && binding.lead_id == lead.id && binding.state == state &&
        binding.upstream_fingerprint == fingerprint && state != "reviewed"
        booking.update!(binding_issue: nil)
        next binding
      end
      raise ArgumentError, "A reason is required to change a booking link" if prior && reason.blank?
      binding.update!(lead: lead, actor: actor, evidence: evidence, state: state, linked_at: Time.current,
        upstream_fingerprint: fingerprint)
      lead.activity_events.create!(kind: "booking_link", summary: "Booking #{booking.ref} linked (#{state})",
        occurred_at: Time.current, metadata: { "perfectbook_id" => booking.perfectbook_id,
          "upstream_fingerprint" => fingerprint, "prior" => prior, "state" => state, "actor" => actor, "evidence" => evidence, "reason" => reason })
      booking.update!(binding_issue: nil)
      AdConversions.correct_booking_owner!(booking, lead: lead)
      binding
    end
  end

  def self.upstream_fingerprint(booking)
    Digest::SHA256.hexdigest(JSON.generate(booking.attributes.slice(
      "crm_inquiry_ref", "perfectbook_contact_id", "trip_id", "trip_name", "departure_id", "start_date").as_json))
  end

  def self.sync!(booking)
    booking.with_lock do
      binding = find_by(perfectbook_id: booking.perfectbook_id)
      if binding
        issue = binding.upstream_fingerprint == upstream_fingerprint(booking) ? nil : "Booking evidence changed; review required"
      elsif booking.crm_inquiry_ref.present?
        lead = Lead.find_by(reference: booking.crm_inquiry_ref)
        issue = if lead.nil?
          "Inquiry reference not found"
        else
          "Unvalidated inquiry reference; review required"
        end
      end
      booking.update!(binding_issue: issue)
    end
  end
end
