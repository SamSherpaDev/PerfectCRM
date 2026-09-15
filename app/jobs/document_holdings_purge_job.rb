# Hourly sweep: purge sensitive holding-area bytes older than 24 hours.
# Hand-off purges immediately; this job covers holdings nobody sent.
class DocumentHoldingsPurgeJob < ApplicationJob
  queue_as :default

  def perform
    DocumentUploadOrphan.purge!
    DocumentHolding.purge_expired!
  end
end
