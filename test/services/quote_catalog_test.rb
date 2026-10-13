require "test_helper"
require "net/http"

class QuoteCatalogTest < ActiveSupport::TestCase
  setup do
    Rails.cache.delete("quote-catalog/product-handles")
    @trip = PerfectBook::Trip.new(perfectbook_id: 42, shopify_product_id: "gid://shopify/Product/123")
    @html = <<~HTML
      <script type="application/ld+json">
        {"@graph":[{"@type":"TouristTrip","offers":[
          {"name":"May (Deposit)","price":500,"priceCurrency":"USD"},
          {"name":"May","price":3975,"priceCurrency":"USD"},
          {"name":"June","price":4200,"priceCurrency":"USD"},
          {"name":"Foreign currency","price":100,"priceCurrency":"EUR"}]}]}
      </script>
      <button role="tab" aria-controls="route">Full itinerary</button>
      <div role="tabpanel" id="route"><p><strong>Days 1 to 3 | Kathmandu</strong></p><p>Meet your guide.</p><p>Day 4 | Walk to the lodge.</p></div>
      <button role="tab" aria-controls="included">Inclusions &amp; exclusions</button>
      <div role="tabpanel" id="included"><p>Included</p><ul><li>Guide and lodges</li></ul><p>Excluded</p><p>International flights</p></div>
    HTML
  end

  teardown do
    Rails.cache.delete("quote-catalog/product-handles")
  end

  test "published full-trip offers exclude deposits and foreign currencies and retain day ranges" do
    requests = []
    source = with_storefront(requests) { QuoteCatalog.snapshot(trip: @trip) }
    assert_equal 397_500, source["price_minor"]
    assert_equal true, source["price_from"]
    assert_equal "Days 1 to 3 | Kathmandu\n\nMeet your guide.\n\nDay 4 | Walk to the lodge.", source["itinerary"]
    assert_equal "Included\n\nGuide and lodges\n\nExcluded\n\nInternational flights", source["included"]
    assert_equal "https://www.sherpaholidays.com/products/example-trip", source["url"]
    assert_equal [ [ "/products.json?limit=250", "application/json" ], [ "/products/example-trip", "text/html" ] ], requests
  end

  test "a priced USD departure supplies an exact price while storefront supplies trip content" do
    departure = PerfectBook::Departure.new(perfectbook_id: 43, currency: "USD", price_per_person_minor: 412_500, synced_at: Time.current)
    source = with_storefront { QuoteCatalog.snapshot(trip: @trip, departure: departure) }
    assert_equal 412_500, source["price_minor"]
    assert_equal false, source["price_from"]
    assert_equal "PerfectBook departure", source["price_source"]
    assert_includes source["itinerary"], "Day 4"
  end

  test "the existing departure mirror can supply a price without a store link" do
    @trip.shopify_product_id = nil
    departure = PerfectBook::Departure.new(perfectbook_id: 43, currency: "USD", price_per_person_minor: 200_000)
    Net::HTTP.stub(:start, ->(*) { flunk "The mirror needs no HTTP call" }) do
      assert_equal 200_000, QuoteCatalog.snapshot(trip: @trip, departure: departure)["price_minor"]
      assert_nil QuoteCatalog.snapshot(trip: @trip)
    end
    departure.currency = "EUR"
    assert_nil QuoteCatalog.snapshot(trip: @trip, departure: departure)
  end

  test "a quoted-on-request trip has no guessed price" do
    @html = @html.sub(/"offers":\[.*?\]/m, '"offers":[]')
    source = with_storefront { QuoteCatalog.snapshot(trip: @trip) }
    assert_nil source["price_minor"]
    assert_includes source["included"], "Excluded"
  end

  test "private journeys use the published minimum-price specification and its occupancy caveat" do
    @html = @html.sub(/"offers":\[.*?\]/m, '"offers":[{"description":"From price per person, based on two travelers sharing a room.","priceSpecification":{"minPrice":27875,"priceCurrency":"USD","unitText":"person"}}]')
    source = with_storefront { QuoteCatalog.snapshot(trip: @trip) }
    assert_equal 2_787_500, source["price_minor"]
    assert_equal true, source["price_from"]
    assert_includes source["price_note"], "based on two travelers sharing a room"
  end

  test "missing published panels and unavailable storefront fail without invented content" do
    @html = "<h1>Trip</h1>"
    assert_raises(QuoteCatalog::Unavailable) { with_storefront { QuoteCatalog.snapshot(trip: @trip) } }
    Net::HTTP.stub(:start, ->(*) { raise Net::ReadTimeout }) do
      assert_raises(QuoteCatalog::Unavailable) { QuoteCatalog.snapshot(trip: @trip) }
    end
  end

  private

  def with_storefront(requests = [])
    transport = Object.new
    html = @html
    get = lambda do |path, headers|
      requests << [ path, headers.fetch("Accept") ]
      body = path.start_with?("/products.json") ? '{"products":[{"id":123,"handle":"example-trip"}]}' : html
      response = Net::HTTPOK.new("1.1", "200", "OK")
      response.body = body
      response.instance_variable_set(:@read, true)
      response
    end
    start = ->(*args, **kwargs, &block) { block.call(transport) }
    transport.define_singleton_method(:get, &get)
    Net::HTTP.stub(:start, start) { yield }
  end
end
