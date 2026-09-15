require "test_helper"

class MemoryEtags
  def initialize
    @store = {}
  end

  def read(key)
    @store[key]
  end

  def write(key, etag)
    @store[key] = etag
  end
end

FakePbResponse = Struct.new(:code, :body, :headers) do
  def [](key)
    headers[key] || headers[key.to_s]
  end
end

class StubPbClient < PerfectBook::Client
  attr_reader :calls

  def initialize(responses:, **kwargs)
    @responses = responses
    @calls = []
    super(base_url: "https://pb.test", api_token: "secret", etag_store: MemoryEtags.new, **kwargs)
  end

  private

  def perform_request(uri, headers)
    @calls << { uri: uri, headers: headers.dup }
    response = @responses.shift || @responses.last
    raise response if response.is_a?(Exception)

    response
  end
end

class PerfectBookClientTest < ActiveSupport::TestCase
  setup do
    PerfectBook::Circuit.reset!
    PerfectBook::EtagStore.delete_all
  end

  teardown do
    PerfectBook::Circuit.reset!
  end

  test "missing local token raises not_configured without an HTTP call" do
    client = PerfectBook::Client.new(base_url: "https://pb.test", api_token: "", etag_store: MemoryEtags.new)
    assert_raises(PerfectBook::NotConfiguredError) { client.list_trips }
  end

  test "unauthorized token raises unauthorized" do
    client = StubPbClient.new(responses: [ FakePbResponse.new("401", '{"error":"unauthorized"}', {}) ])
    assert_raises(PerfectBook::UnauthorizedError) { client.list_trips }
  end

  test "collection 404 means PerfectBook has no token configured" do
    client = StubPbClient.new(responses: [ FakePbResponse.new("404", '{"error":"not found"}', {}) ])
    assert_raises(PerfectBook::NotConfiguredError) { client.list_contacts }
  end

  test "member 404 raises not_found" do
    client = StubPbClient.new(responses: [ FakePbResponse.new("404", '{"error":"not found"}', {}) ])
    assert_raises(PerfectBook::NotFoundError) { client.fetch_contact(9) }
  end

  test "walks cursor pagination across pages" do
    page1 = { "data" => [ { "id" => 1, "name" => "A", "active" => true, "status" => "active" } ],
              "pagination" => { "has_more" => true, "next_cursor" => "1" } }.to_json
    page2 = { "data" => [ { "id" => 2, "name" => "B", "active" => true, "status" => "active" } ],
              "pagination" => { "has_more" => false, "next_cursor" => nil } }.to_json
    client = StubPbClient.new(responses: [
      FakePbResponse.new("200", page1, { "ETag" => '"p1"' }),
      FakePbResponse.new("200", page2, { "ETag" => '"p2"' })
    ])
    result = client.list_trips
    assert_equal false, result[:not_modified]
    assert_equal [ 1, 2 ], result[:data].map(&:id)
    assert_equal 2, client.calls.size
    assert_match(/cursor=1/, client.calls.second[:uri].query)
  end

  test "etag 304 on first page returns not_modified" do
    etags = MemoryEtags.new
    etags.write("GET /api/v1/trips?limit=100", '"abc"')
    client = StubPbClient.new(responses: [ FakePbResponse.new("304", "", {}) ], etag_store: etags)
    # Seed the same cache key the client will compute (limit=100 default).
    result = client.list_trips
    assert_equal true, result[:not_modified]
    assert_equal [], result[:data]
    assert_equal '"abc"', client.calls.first[:headers]["If-None-Match"]
  end

  test "rate limit carries retry-after seconds" do
    client = StubPbClient.new(responses: [ FakePbResponse.new("429", '{"error":"slow"}', { "Retry-After" => "7" }) ])
    error = assert_raises(PerfectBook::RateLimitedError) { client.list_trips }
    assert_equal 7, error.retry_after
  end

  test "rate limit without header has nil retry-after" do
    client = StubPbClient.new(responses: [ FakePbResponse.new("429", '{"error":"slow"}', {}) ])
    error = assert_raises(PerfectBook::RateLimitedError) { client.list_trips }
    assert_nil error.retry_after
  end

  test "timeouts become unavailable" do
    client = StubPbClient.new(responses: [ Net::ReadTimeout.new("timed out") ])
    assert_raises(PerfectBook::UnavailableError) { client.list_trips }
  end

  test "server errors become unavailable" do
    client = StubPbClient.new(responses: [ FakePbResponse.new("503", "bad", {}) ])
    assert_raises(PerfectBook::UnavailableError) { client.list_trips }
  end

  test "circuit opens after repeated failures and skips HTTP" do
    failures = Array.new(6) { FakePbResponse.new("503", "bad", {}) }
    client = StubPbClient.new(responses: failures)
    5.times { assert_raises(PerfectBook::UnavailableError) { client.list_trips } }
    assert PerfectBook::Circuit.open?
    calls_before = client.calls.size
    assert_raises(PerfectBook::CircuitOpenError) { client.list_trips }
    assert_equal calls_before, client.calls.size
  end

  test "success resets the circuit" do
    client = StubPbClient.new(responses: [ FakePbResponse.new("503", "bad", {}) ])
    assert_raises(PerfectBook::UnavailableError) { client.list_trips }
    ok_body = { "data" => [], "pagination" => { "has_more" => false } }.to_json
    client2 = StubPbClient.new(responses: [ FakePbResponse.new("200", ok_body, {}) ])
    # Share the same global circuit: one success clears the single failure.
    client2.list_trips
    assert_not PerfectBook::Circuit.open?
  end

  test "authorization header never lands in the logs" do
    logged = []
    logger = Logger.new(nil)
    logger.formatter = ->(_sev, _time, _prog, msg) { logged << msg; "" }
    old_logger = Rails.logger
    Rails.logger = logger
    begin
      ok_body = { "data" => [], "pagination" => { "has_more" => false } }.to_json
      client = StubPbClient.new(responses: [ FakePbResponse.new("200", ok_body, {}) ])
      client.list_trips
    ensure
      Rails.logger = old_logger
    end
    assert logged.none? { |line| line.to_s.include?("secret") }
  end

  test "contact payload maps all fields including null phone" do
    row = { "id" => 3, "kind" => "customer", "name" => "Ama", "email" => "a@example.test",
            "phone" => nil, "country" => "NP", "state" => "Bagmati",
            "archived" => false, "created_at" => "2026-01-01T00:00:00Z",
            "updated_at" => "2026-02-01T00:00:00Z" }
    body = { "data" => [ row ], "pagination" => { "has_more" => false } }.to_json
    client = StubPbClient.new(responses: [ FakePbResponse.new("200", body, {}) ])
    contact = client.list_contacts[:data].first
    assert_equal 3, contact.id
    assert_nil contact.phone
    assert_equal "Ama", contact.name
  end

  test "booking payload maps trip, departure, and invoice badge" do
    row = { "id" => 11, "ref" => "SH-1", "status" => "deposit_received",
            "trip" => { "id" => 2, "name" => "Everest" },
            "departure" => { "id" => 5, "place" => "Lukla", "start_date" => "2026-10-01", "end_date" => "2026-10-14" },
            "party_size" => 2, "price_per_person_minor" => 10000, "total_minor" => 20000,
            "paid_minor" => 5000, "balance_due_minor" => 15000, "currency" => "USD",
            "invoice" => { "badge" => "partially_paid", "number" => "SH-2026-0001", "payment_reference" => "SH20260001" },
            "deep_link" => "https://pb.test/bookings/11" }
    # list_contact_bookings paginates; the bookings endpoint wraps rows the same way.
    body = { "data" => [ row ], "pagination" => { "has_more" => false } }.to_json
    client = StubPbClient.new(responses: [ FakePbResponse.new("200", body, {}) ])
    booking = client.list_contact_bookings(7)[:data].first
    assert_equal "SH-1", booking.ref
    assert_equal "Everest", booking.trip_name
    assert_equal "partially_paid", booking.invoice_badge
    assert_equal "https://pb.test/bookings/11", booking.deep_link
  end
end
