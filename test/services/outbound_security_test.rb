require "test_helper"
require_relative "../support/graph_fake"

class OutboundSecurityTest < ActiveSupport::TestCase
  { "AI" => :ai_base_url, "LEAD_WEBHOOK" => :lead_webhook_url }.each do |service, attribute|
    test "revoking #{service} origin blocks delivery without blocking unrelated settings saves" do
      key = "#{service}_ALLOWED_ORIGINS"
      previous = ENV[key]
      ENV[key] = "https://revocable.example"
      settings = Setting.current
      settings.update!(attribute => "https://revocable.example/v1")
      settings.update!(ms_graph_refresh_token: "refresh-0")
      ENV[key] = ""

      settings.update!(appearance: "night", digest_enabled: false, sender_name: "Captain")
      assert_equal "night", settings.reload.appearance
      assert_not settings.digest_enabled
      assert_equal "Captain", settings.sender_name
      transport = FakeMailbox.new.transport
      assert_equal "access-1", Mail::GraphAuth.access_token!(transport: transport)
      assert_equal "refresh-2", settings.reload.ms_graph_refresh_token

      Net::HTTP.stub(:new, ->(*) { flunk "Webhook transport reached" }) do
        Net::HTTP.stub(:start, ->(*) { flunk "AI transport reached" }) do
          assert_raises(ArgumentError) do
            if service == "AI"
              Ai::OpenAiAdapter.new(base_url: settings.ai_base_url, model: "synthetic", api_key: "secret")
                .chat(system: "synthetic", messages: [])
            else
              lead = Lead.create!(name: "Synthetic customer")
              LeadWebhookJob.new.perform(lead.id, "lead.created")
            end
          end
        end
      end

      settings.public_send("#{attribute}=", "https://revocable.example/changed")
      assert_not settings.save
      assert settings.errors[attribute].present?
      settings.public_send("#{attribute}=", "")
      assert settings.save

      fresh = Setting.new(attribute => "https://revocable.example/v1")
      assert_not fresh.valid?
      assert fresh.errors[attribute].present?
    ensure
      ENV[key] = previous
    end
  end

  test "settings reject unencrypted credential and webhook endpoints" do
    settings = Setting.current
    settings.lead_webhook_url = "http://127.0.0.1:9876/security-probe"
    settings.ai_base_url = "http://127.0.0.1:9876/v1"
    assert_not settings.valid?
    assert settings.errors[:lead_webhook_url].present?
    assert settings.errors[:ai_base_url].present?
  end

  test "Graph rejects an unexpected absolute origin before requesting credentials or transport" do
    transport = Object.new
    transport.define_singleton_method(:get_json) { |*args, **kwargs| raise "Transport reached" }
    transport.define_singleton_method(:get_bytes) { |*args, **kwargs| raise "Transport reached" }
    client = Mail::GraphClient.new(transport: transport) { flunk "Token source reached" }
    [ "https://unexpected.example/v1.0/me", "http://graph.microsoft.com/v1.0/me",
      "https://graph.microsoft.com.evil.test/me", "https://graph.microsoft.com:444/me",
      "https://user:password@graph.microsoft.com/me", "//unexpected.example/me",
      "https://graph.microsoft.com/me#fragment" ].each do |url|
      assert_raises(ArgumentError) { client.get_json(url) }
      assert_raises(ArgumentError) { client.get_bytes(url) }
    end
  end

  test "Graph accepts relative paths and Microsoft continuation links" do
    urls = []
    transport = Object.new
    transport.define_singleton_method(:get_json) do |url, token:, **kwargs|
      urls << [ url, token ]
      Mail::GraphTransport::Response.new(status: 200, body: '{"value":[]}')
    end
    client = Mail::GraphClient.new(transport: transport) { "synthetic-token" }
    client.get_json("/me")
    client.get_json("https://graph.microsoft.com/v1.0/me/messages?$deltatoken=synthetic")
    assert_equal [ [ "https://graph.microsoft.com/v1.0/me", "synthetic-token" ],
      [ "https://graph.microsoft.com/v1.0/me/messages?$deltatoken=synthetic", "synthetic-token" ] ], urls
  end

  test "Graph transport rejects unexpected origins before building any authenticated request" do
    transport = Mail::GraphTransport.new
    Net::HTTP.stub(:new, ->(*) { flunk "HTTP transport reached" }) do
      assert_raises(ArgumentError) { transport.get_json("https://unexpected.example/me", token: "secret") }
      assert_raises(ArgumentError) { transport.get_bytes("http://graph.microsoft.com/me", token: "secret") }
      assert_raises(ArgumentError) { transport.post_form("https://unexpected.example/token", client_secret: "secret") }
      assert_raises(ArgumentError) { transport.post_form("http://login.microsoftonline.com/token", client_secret: "secret") }
    end
  end

  test "AI and PerfectBook refuse HTTP and unapproved origins before transport" do
    Net::HTTP.stub(:start, ->(*) { flunk "AI transport reached" }) do
      [ "http://api.openai.com/v1", "https://unexpected.example/v1", "https://api.openai.com:444/v1" ].each do |url|
        adapter = Ai::OpenAiAdapter.new(base_url: url, model: "synthetic", api_key: "secret")
        assert_raises(ArgumentError) { adapter.chat(system: "synthetic", messages: []) }
      end
    end
    Net::HTTP.stub(:new, ->(*) { flunk "PerfectBook transport reached" }) do
      [ "http://perfectbook.sherpaholidays.com", "https://unexpected.example" ].each do |url|
        assert_raises(ArgumentError) { PerfectBook::Client.new(base_url: url, api_token: "secret").test_connection }
      end
    end
  end

  test "stored webhook URLs are rechecked at delivery time" do
    settings = Setting.current
    settings.ensure_intake_credentials!
    settings.update_column(:lead_webhook_url, "http://127.0.0.1:9876/security-probe")
    lead = Lead.create!(name: "Synthetic customer")
    Net::HTTP.stub(:new, ->(*) { flunk "Webhook transport reached" }) do
      assert_raises(ArgumentError) { LeadWebhookJob.new.perform(lead.id, "lead.created") }
    end
  end

  test "private HTTPS deployments require an explicit origin and HTTP is never allowed" do
    previous = ENV["AI_ALLOWED_ORIGINS"]
    ENV["AI_ALLOWED_ORIGINS"] = ""
    assert_raises(ArgumentError) { OutboundEndpoint.for_service!("https://127.0.0.1:9443/v1", service: "AI") }
    ENV["AI_ALLOWED_ORIGINS"] = "https://127.0.0.1:9443"
    assert_equal "127.0.0.1", OutboundEndpoint.for_service!("https://127.0.0.1:9443/v1", service: "AI").hostname
    assert_raises(ArgumentError) { OutboundEndpoint.for_service!("http://127.0.0.1:9443/v1", service: "AI") }
    assert_raises(ArgumentError) { OutboundEndpoint.for_service!("https://127.0.0.1:9444/v1", service: "AI") }
  ensure
    ENV["AI_ALLOWED_ORIGINS"] = previous
  end
end
