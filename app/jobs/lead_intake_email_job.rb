# Sends the new-inquiry email copy to the captain after the lead row
# commits. 5 retries over ~30 minutes; a mail failure after retries raises
# the operator alert through the job backend and never touches the lead.
class LeadIntakeEmailJob < ApplicationJob
  queue_as :default

  retry_on StandardError, attempts: 6, wait: ->(executions) { [ 30, 120, 300, 480, 720 ][executions - 1] || 720 }

  discard_on ActiveJob::DeserializationError

  def perform(lead_id)
    lead = Lead.find(lead_id)
    LeadIntakeMailer.inquiry_copy(lead).deliver_now
  end
end
