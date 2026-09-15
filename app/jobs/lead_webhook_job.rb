class LeadWebhookJob < ApplicationJob
  queue_as :default

  retry_on StandardError, attempts: 6, wait: :polynomially_longer

  discard_on ActiveJob::DeserializationError

  def perform(lead_id, event)
    lead = Lead.find(lead_id)
    settings = Setting.current
    url = settings.lead_webhook_url
    return if url.blank?

    secret = settings.ensure_intake_credentials!.relay_secret
    deliver_to(lead, event, url, secret)
  end

  private

  def deliver_to(lead, event, url, secret)
    delivery = LeadWebhookDelivery.create!(lead: lead, event: event, url: url)
    body = JSON.generate(webhook_payload(lead, event))
    signature = ::Leads.sign_relay_body(body, secret)

    attempts = 0
    begin
      attempts += 1
      response = post(url, body, signature)
      delivery.update!(
        attempts: attempts,
        http_status: response.code.to_i,
        status: response.is_a?(Net::HTTPSuccess) ? "delivered" : "failed",
        error: response.is_a?(Net::HTTPSuccess) ? nil : "HTTP #{response.code}"
      )
      raise WebhookFailed, "HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)
    rescue StandardError => e
      delivery.update!(attempts: attempts, status: "failed", error: e.message.truncate(300))
      raise
    end
  end

  def post(url, body, signature)
    uri = URI.parse(url)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = uri.scheme == "https"
    http.open_timeout = 10
    http.read_timeout = 10
    request = Net::HTTP::Post.new(uri.request_uri,
      "Content-Type" => "application/json",
      "X-Sherpa-Signature" => signature)
    request.body = body
    http.request(request)
  end

  def webhook_payload(lead, event)
    attribution = lead.metadata.is_a?(Hash) ? lead.metadata["attribution"] || {} : {}
    {
      event: event,
      lead: {
        id: lead.id,
        reference: lead.reference,
        name: lead.name,
        email: lead.email,
        phone: lead.phone,
        trip_handle: lead.trip_handle,
        trip_title: lead.trip_title,
        message: lead.message,
        source: lead.source,
        campaign_name: lead.campaign_name,
        placement: lead.placement,
        status: lead.status,
        fit_score: lead.fit_score,
        fit_band: lead.fit_band,
        travel_month: lead.travel_month,
        travel_year: lead.travel_year,
        timing_unknown: lead.timing_unknown,
        party_size: lead.party_size,
        budget_band: lead.budget_band,
        attribution: attribution,
        received_at: (lead.received_at || lead.created_at)&.iso8601
      }
    }
  end

  class WebhookFailed < StandardError; end
end
