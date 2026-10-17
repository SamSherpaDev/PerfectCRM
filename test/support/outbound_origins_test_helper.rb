module OutboundOriginsTestHelper
  extend ActiveSupport::Concern

  included do
    setup do
      @old_outbound_origins = ENV.to_h.slice("LEAD_WEBHOOK_ALLOWED_ORIGINS", "PERFECTBOOK_ALLOWED_ORIGINS")
      ENV["LEAD_WEBHOOK_ALLOWED_ORIGINS"] = "https://n8n.example.com"
      ENV["PERFECTBOOK_ALLOWED_ORIGINS"] = "https://pb.test"
    end

    teardown do
      %w[LEAD_WEBHOOK_ALLOWED_ORIGINS PERFECTBOOK_ALLOWED_ORIGINS].each do |key|
        ENV[key] = @old_outbound_origins[key]
      end
    end
  end
end
