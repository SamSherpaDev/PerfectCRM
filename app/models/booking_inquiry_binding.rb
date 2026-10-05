# One primary inquiry per PerfectBook booking, independent of the mirror's lifecycle.
class BookingInquiryBinding < ApplicationRecord
  belongs_to :lead
  validates :perfectbook_id, presence: true, uniqueness: true
  validates :state, inclusion: { in: %w[explicit inferred reviewed] }
  validates :actor, :evidence, :linked_at, presence: true

  def self.link!(booking, lead:, actor:, evidence:, state: "reviewed", reason: nil)
    transaction do
      binding = find_or_initialize_by(perfectbook_id: booking.perfectbook_id)
      prior = binding.persisted? ? binding.attributes.slice("lead_id", "state", "evidence") : nil
      return binding if binding.persisted? && binding.lead_id == lead.id && binding.state == state
      raise ArgumentError, "A reason is required to change a booking link" if prior && reason.blank?
      binding.update!(lead: lead, actor: actor, evidence: evidence, state: state, linked_at: Time.current)
      lead.activity_events.create!(kind: "booking_link", summary: "Booking #{booking.ref} linked (#{state})",
        occurred_at: Time.current, metadata: { "perfectbook_id" => booking.perfectbook_id,
          "prior" => prior, "state" => state, "actor" => actor, "evidence" => evidence, "reason" => reason })
      binding
    end
  end

  def self.sync!(booking)
    return if booking.crm_inquiry_ref.blank?
    lead = Lead.find_by(reference: booking.crm_inquiry_ref)
    binding = find_by(perfectbook_id: booking.perfectbook_id)
    issue = if lead.nil?
      "Inquiry reference not found"
    elsif binding && binding.lead_id != lead.id
      "Inquiry reference changed; review required"
    else
      ids = [ lead.perfectbook_contact_id, lead.converted_client&.perfectbook_contact_id, lead.existing_client&.perfectbook_contact_id ].compact
      if !ids.include?(booking.perfectbook_contact_id)
        "Contact mismatch; review required"
      elsif [ lead.trip_title, lead.trip_interest ].compact_blank.any? && ![ lead.trip_title, lead.trip_interest ].include?(booking.trip_name)
        "Trip mismatch; review required"
      elsif booking.start_date && ((lead.travel_month && lead.travel_month != booking.start_date.month) || (lead.travel_year && lead.travel_year != booking.start_date.year))
        "Departure month mismatch; review required"
      end
    end
    if issue.nil?
      link!(booking, lead: lead, actor: "PerfectBook sync", evidence: "crm_inquiry_ref:#{booking.crm_inquiry_ref}", state: "explicit", reason: "PerfectBook explicit reference")
    end
    booking.update!(binding_issue: issue)
  end
end
