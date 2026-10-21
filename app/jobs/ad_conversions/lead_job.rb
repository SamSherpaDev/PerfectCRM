# Sends the Meta Lead, QualifiedLead, and Schedule events right after a website
# inquiry lands, the owner marks it Potential, or a call is scheduled, because
# Meta weighs events that arrive within the hour. The nightly
# AdConversions::ExportJob retries anything this misses.
class AdConversions::LeadJob < ApplicationJob
  queue_as :default

  def perform(lead_id)
    settings = Setting.current
    return unless AdConversions.enabled?(settings)

    lead = Lead.find_by(id: lead_id)
    return unless lead

    AdConversions.record!(lead)
    lead.ad_conversions.where(event: %w[lead qualified call_scheduled]).order(:occurred_at, :id).each do |row|
      AdConversions.deliver_meta!(row, settings: settings)
    end
  end
end
