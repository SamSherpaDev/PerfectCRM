require "test_helper"
require "stringio"

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

  test "validators remain uncommitted until the consumer succeeds" do
    etags = MemoryEtags.new
    body = { data: [], pagination: { has_more: false } }.to_json
    client = StubPbClient.new(responses: [ FakePbResponse.new("200", body, { "ETag" => '"new"' }) ], etag_store: etags)
    result = client.list_trips
    assert_nil etags.read("GET /api/v1/trips?limit=100")
    result[:commit_etags].call
    assert_equal '"new"', etags.read("GET /api/v1/trips?limit=100")
  end

  test "failed pagination leaves validators unchanged" do
    etags = MemoryEtags.new
    body = { data: [], pagination: { has_more: true, next_cursor: "1" } }.to_json
    client = StubPbClient.new(responses: [ FakePbResponse.new("200", body, { "ETag" => '"new"' }), Net::ReadTimeout.new ], etag_store: etags)
    assert_raises(PerfectBook::UnavailableError) { client.list_trips }
    assert_nil etags.read("GET /api/v1/trips?limit=100")
  end

  test "unchanged continuation pages are fetched without validators" do
    etags = MemoryEtags.new
    etags.write("GET /api/v1/trips?limit=100&cursor=1", '"old"')
    first = { data: [ { id: 1 } ], pagination: { has_more: true, next_cursor: "1" } }.to_json
    last = { data: [ { id: 2 } ], pagination: { has_more: false } }.to_json
    client = StubPbClient.new(responses: [ FakePbResponse.new("200", first, {}), FakePbResponse.new("304", "", {}), FakePbResponse.new("200", last, {}) ], etag_store: etags)
    assert_equal [ 1, 2 ], client.list_trips[:data].map(&:id)
    assert_equal '"old"', client.calls.second[:headers]["If-None-Match"]
    assert_nil client.calls.third[:headers]["If-None-Match"]
  end

  test "paced requests pause for rate limits and between pages" do
    first = { data: [], pagination: { has_more: true, next_cursor: "1" } }.to_json
    last = { data: [], pagination: { has_more: false } }.to_json
    client = StubPbClient.new(responses: [ FakePbResponse.new("429", "", { "Retry-After" => "7" }), FakePbResponse.new("200", first, {}), FakePbResponse.new("200", last, {}) ], pace_requests: true)
    pauses = []
    client.define_singleton_method(:sleep) { |seconds| pauses << seconds }
    assert_equal false, client.list_trips[:not_modified]
    assert_equal 7, pauses.first
    assert pauses.last.positive?
    assert_equal 3, client.calls.size
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
    logged = StringIO.new
    logger = Logger.new(logged)
    old_logger = Rails.logger
    Rails.logger = logger
    begin
      ok_body = { "data" => [], "pagination" => { "has_more" => false } }.to_json
      client = StubPbClient.new(responses: [ FakePbResponse.new("200", ok_body, {}) ])
      client.list_trips
    ensure
      Rails.logger = old_logger
    end
    assert_includes logged.string, "PerfectBook GET /api/v1/trips -> 200"
    assert_not_includes logged.string, "secret"
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

  test "booking payload maps the documents summary and checklist" do
    row = { "id" => 11, "ref" => "SH-1", "status" => "deposit_received",
            "trip" => { "id" => 2, "name" => "Everest" },
            "departure" => { "id" => 5, "place" => "Lukla", "start_date" => "2026-10-01", "end_date" => "2026-10-14" },
            "party_size" => 2, "price_per_person_minor" => 10000, "total_minor" => 20000,
            "paid_minor" => 5000, "balance_due_minor" => 15000, "currency" => "USD",
            "invoice" => { "badge" => "partially_paid", "number" => "SH-2026-0001", "payment_reference" => "SH20260001" },
            "documents" => { "travelers" => [ { "id" => 3, "first_name" => "Ama",
              "documents" => [ { "type" => "passport", "status" => "received", "received_at" => "2026-08-01" } ] } ],
              "missing_count" => 0 },
            "checklist" => [ { "key" => "payment", "label" => "Payment", "done" => true } ],
            "deep_link" => "https://pb.test/bookings/11" }
    body = { "data" => [ row ], "pagination" => { "has_more" => false } }.to_json
    client = StubPbClient.new(responses: [ FakePbResponse.new("200", body, {}) ])
    booking = client.list_contact_bookings(7)[:data].first
    assert_equal 0, booking.missing_count
    assert_equal "Ama", booking.documents["travelers"].first["first_name"]
    assert_equal true, booking.checklist.first["done"]
  end

  def stub_upload_client(response)
    client = PerfectBook::Client.new(base_url: "https://pb.test", api_token: "secret", etag_store: MemoryEtags.new)
    calls = []
    client.define_singleton_method(:perform_upload) do |booking_ref, traveler_id, **kwargs|
      calls << { booking_ref: booking_ref, traveler_id: traveler_id, **kwargs }
      response
    end
    [ client, calls ]
  end

  def upload_ok_body(duplicate: false)
    { "data" => { "traveler" => { "id" => 3, "first_name" => "Ama" },
      "document" => { "type" => "passport", "status" => "received", "received_at" => "2026-09-15" },
      "missing_count" => 1, "duplicate" => duplicate } }.to_json
  end

  test "upload posts multipart fields and parses the created response" do
    client, calls = stub_upload_client(FakePbResponse.new("201", upload_ok_body, {}))
    result = client.upload_traveler_document(booking_ref: "BK-11", traveler_id: 3,
      file: "%PDF-bytes", filename: "passport.pdf", content_type: "application/pdf",
      document_type: "passport", upload_id: "holding-9")
    assert_equal "BK-11", calls.first[:booking_ref]
    assert_equal 3, calls.first[:traveler_id]
    assert_equal "holding-9", calls.first[:upload_id]
    assert_equal "passport", calls.first[:document_type]
    assert_equal 3, result.traveler_id
    assert_equal "received", result.document_status
    assert_equal 1, result.missing_count
    assert_equal false, result.duplicate
  end

  test "upload emits binary multipart content with escaped Unicode filenames" do
    client = PerfectBook::Client.new(base_url: "https://pb.test", api_token: "secret",
      etag_store: MemoryEtags.new)
    requests = []
    http = Net::HTTP.new("pb.test", 443)
    data = "\xFF\xD8\xE9\x00".b
    filename = "José-\"passport\".jpg"
    http.stub(:request, ->(request) {
      requests << request
      FakePbResponse.new("201", upload_ok_body, {})
    }) do
      Net::HTTP.stub(:new, http) do
        result = client.upload_traveler_document(booking_ref: "BK-11", traveler_id: 3,
          file: data, filename: filename, content_type: "image/jpeg",
          document_type: "passport", upload_id: "holding-9")
        assert_equal "received", result.document_status
      end
    end
    request = requests.fetch(0)
    assert_equal Encoding::BINARY, request.body.encoding
    assert_includes request.body, 'filename="José-%22passport%22.jpg"'.b
    assert_includes request.body, "\r\n\r\n".b + data + "\r\n".b
    assert_includes request.body, "name=\"upload_id\"\r\n\r\nholding-9".b
  end

  test "upload replay returns duplicate without an error" do
    client, _calls = stub_upload_client(FakePbResponse.new("200", upload_ok_body(duplicate: true), {}))
    result = client.upload_traveler_document(booking_ref: "BK-11", traveler_id: 3,
      file: "%PDF-bytes", filename: "passport.pdf", content_type: "application/pdf",
      document_type: "passport", upload_id: "holding-9")
    assert_equal true, result.duplicate
  end

  test "upload maps rejection statuses to errors" do
    { "400" => PerfectBook::BadRequestError, "401" => PerfectBook::UnauthorizedError,
      "404" => PerfectBook::NotFoundError, "422" => PerfectBook::UnprocessableError,
      "503" => PerfectBook::UnavailableError }.each do |code, error|
      client, _calls = stub_upload_client(FakePbResponse.new(code, '{"error":"nope"}', {}))
      assert_raises(error) do
        client.upload_traveler_document(booking_ref: "BK-11", traveler_id: 3,
          file: "x", filename: "passport.pdf", content_type: "application/pdf",
          document_type: "passport", upload_id: "holding-9")
      end
    end
  end
end
