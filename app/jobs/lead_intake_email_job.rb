class LeadIntakeEmailJob < ApplicationJob
  queue_as :default

  def perform(lead_id)
    lead = Lead.find(lead_id)
    LeadIntakeMailer.inquiry_copy(lead).deliver_now
  end
end
