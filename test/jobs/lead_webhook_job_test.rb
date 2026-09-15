require "test_helper"

class LeadWebhookJobTest < ActiveJob::TestCase
  FakeResponse = Struct.new(:code) do
    def is_a?(klass)
      return code.start_with?("2") if klass == Net::HTTPSuccess

      super
    end
  end

  class FakeHttp
    attr_reader :bodies, :signatures
    attr_accessor :code

    def initialize(code = "200")
      @code = code
      @bodies = []
      @signatures = []
    end

    def use_ssl=(_); end
    def open_timeout=(_); end
    def read_timeout=(_); end

    def request(req)
      @bodies << req.body
      @signatures << req["X-Sherpa-Signature"]
      FakeResponse.new(@code)
    end
  end

  setup do
    @settings = Setting.current
    @relay_secret = @settings.rotate_relay_secret!
    @lead = Lead.create!(name: "Anna Lindqvist", email: "anna@example.com", source: "website_form")
    @http = FakeHttp.new
    @http_holder = @http
  end

  def with_fake_http(code: "200")
    fake = FakeHttp.new(code)
    Net::HTTP.stub(:new, ->(*_) { fake }) { yield fake }
  end

  test "posts a signed lead.created to the subscription and logs delivery" do
    @settings.update!(lead_webhook_url: "https://n8n.example.com/hook")
    with_fake_http do |fake|
      LeadWebhookJob.perform_now(@lead.id, "lead.created")
      assert_equal 1, fake.bodies.size
      payload = JSON.parse(fake.bodies.first)
      assert_equal "lead.created", payload["event"]
      assert_equal @lead.reference, payload["lead"]["reference"]
      assert_equal "anna@example.com", payload["lead"]["email"]

      fake.signatures.each do |signature|
        caller_name = ::Leads.verify_relay_signature(fake.bodies.first, signature, secret: @relay_secret)
        assert_equal "relay", caller_name
      end
    end
    deliveries = LeadWebhookDelivery.order(:id).last(1)
    assert_equal %w[delivered], deliveries.map(&:status)
    assert_equal [ 1 ], deliveries.map(&:attempts)
    assert_equal [ 200 ], deliveries.map(&:http_status)
  end

  test "a 500 response records a failed attempt and raises for retry" do
    @settings.update!(lead_webhook_url: "https://n8n.example.com/hook")
    with_fake_http(code: "500") do |fake|
      assert_raises(LeadWebhookJob::WebhookFailed) do
        LeadWebhookJob.new.perform(@lead.id, "lead.created")
      end
      assert_equal 1, fake.bodies.size
    end
    delivery = LeadWebhookDelivery.last
    assert_equal "failed", delivery.status
    assert_equal "lead.created", delivery.event
    assert_equal 1, delivery.attempts
    assert_equal 500, delivery.http_status
  end

  test "an empty webhook URL disables delivery" do
    @settings.update!(lead_webhook_url: nil)
    with_fake_http do |fake|
      LeadWebhookJob.perform_now(@lead.id, "lead.created")
      assert_empty fake.bodies
    end
    assert_equal 0, LeadWebhookDelivery.count
  end

end
