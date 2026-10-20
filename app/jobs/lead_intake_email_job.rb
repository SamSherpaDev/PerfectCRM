class LeadIntakeEmailJob < ApplicationJob
  queue_as :default

  def perform(lead_id)
    lead = Lead.find_by(id: lead_id)
    return unless LeadIntakeMailer.real_inquiry?(lead)

    LeadIntakeMailer.inquiry_copy(lead).deliver_now
  end
end
