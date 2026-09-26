# Sends the Meta Lead event right after a website inquiry lands, because
# Meta weighs events that arrive within the hour. The hourly
# AdConversions::ExportJob retries anything this misses.
class AdConversions::LeadJob < ApplicationJob
  queue_as :default

  def perform(lead_id)
    settings = Setting.current
    return unless AdConversions.enabled?(settings)

    lead = Lead.find_by(id: lead_id)
    return unless lead

    AdConversions.record!(lead)
    row = lead.ad_conversions.find_by(event: "lead")
    AdConversions.deliver_meta!(row, settings: settings) if row
  end
end
