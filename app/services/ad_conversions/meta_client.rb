# frozen_string_literal: true

require "net/http"

module AdConversions
  # Meta Conversions API: one event per request so an error belongs to one
  # row. User data is SHA-256 hashed as Meta requires; the access token
  # travels in the body and never reaches logs or stored errors.
  class MetaClient
    class Error < StandardError; end

    GRAPH_VERSION = "v24.0"

    def initialize(settings)
      @settings = settings
    end

    def deliver(row)
      response = post(JSON.generate(body(row)))
      parsed = JSON.parse(response.body.to_s) rescue {}
      unless response.is_a?(Net::HTTPSuccess) && parsed["events_received"].to_i >= 1
        message = parsed.dig("error", "error_user_msg").presence || parsed.dig("error", "message").presence
        raise Error, [ "HTTP #{response.code}", message ].compact.join(": ")
      end
      parsed
    rescue Timeout::Error, SystemCallError, SocketError, OpenSSL::SSL::SSLError, IOError, EOFError => error
      raise Error, "#{error.class}: #{error.message}"
    end

    def body(row)
      payload = { data: [ event(row) ], access_token: @settings.meta_access_token }
      payload[:test_event_code] = @settings.meta_test_event_code if @settings.meta_test_event_code.present?
      payload
    end

    def event(row)
      lead = row.lead
      user_agent = lead.metadata.is_a?(Hash) ? lead.metadata["user_agent"].to_s.presence : nil
      website = row.event == "lead" && user_agent.present?
      data = {
        event_name: row.meta_event_name,
        event_time: row.occurred_at.to_i,
        event_id: row.event_id,
        action_source: website ? "website" : "system_generated",
        user_data: user_data(lead, user_agent),
        custom_data: { value: row.value_dollars, currency: row.currency }
      }
      data[:event_source_url] = source_url(lead) if website && source_url(lead)
      data
    end

    private

    def user_data(lead, user_agent)
      email = AdConversions.contact_email(lead)
      phone = AdConversions.contact_phone(lead)
      data = { external_id: [ AdConversions.sha256(lead.id.to_s) ] }
      data[:em] = [ AdConversions.meta_email_hash(email) ] if email
      data[:ph] = [ AdConversions.meta_phone_hash(phone) ] if phone
      data[:fbc] = fbc(lead) if AdConversions.fbclid(lead)
      data[:client_user_agent] = user_agent if user_agent
      data
    end

    # fb.1.<click time in ms>.<fbclid>, Meta's click cookie format.
    def fbc(lead)
      "fb.1.#{(AdConversions.click_at(lead).to_f * 1000).to_i}.#{AdConversions.fbclid(lead)}"
    end

    def source_url(lead)
      page = lead.metadata.is_a?(Hash) ? lead.metadata["page"] : nil
      url = page.is_a?(Hash) ? page["url"].to_s.presence : nil
      url || AdConversions.attribution(lead)["landing_url"].to_s.presence
    end

    def post(body)
      uri = URI.parse("https://graph.facebook.com/#{GRAPH_VERSION}/#{@settings.meta_dataset_id}/events")
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.open_timeout = 10
      http.read_timeout = 15
      request = Net::HTTP::Post.new(uri.request_uri, "Content-Type" => "application/json")
      request.body = body
      http.request(request)
    end
  end
end
