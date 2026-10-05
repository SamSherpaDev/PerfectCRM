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
      return binding if binding.persisted? && binding.lead_id == lead.id && binding.state == state && state != "reviewed"
      raise ArgumentError, "A reason is required to change a booking link" if prior && reason.blank?
      binding.update!(lead: lead, actor: actor, evidence: evidence, state: state, linked_at: Time.current)
      lead.activity_events.create!(kind: "booking_link", summary: "Booking #{booking.ref} linked (#{state})",
        occurred_at: Time.current, metadata: { "perfectbook_id" => booking.perfectbook_id,
          "upstream" => upstream_evidence(booking), "prior" => prior, "state" => state, "actor" => actor, "evidence" => evidence, "reason" => reason })
      binding
    end
  end

  def self.upstream_evidence(booking)
    booking.attributes.slice("crm_inquiry_ref", "perfectbook_contact_id", "trip_name", "start_date").as_json
  end

  def self.sync!(booking)
    binding = find_by(perfectbook_id: booking.perfectbook_id)
    if binding
      review = binding.lead.activity_events.where(kind: "booking_link")
        .where("json_extract(metadata, '$.perfectbook_id') = ?", booking.perfectbook_id).order(:id).last
      issue = review&.metadata&.dig("upstream") == upstream_evidence(booking) ? nil : "Booking evidence changed; review required"
    elsif booking.crm_inquiry_ref.present?
      lead = Lead.find_by(reference: booking.crm_inquiry_ref)
      issue = if lead.nil?
        "Inquiry reference not found"
      elsif binding && binding.lead_id != lead.id
        "Inquiry reference changed; review required"
      else
        "Unvalidated inquiry reference; review required"
      end
    end
    booking.update!(binding_issue: issue)
  end
end
