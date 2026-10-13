# Read-only trip details from the published SherpaHolidays storefront and the
# existing PerfectBook departure mirror. No credentials or store writes.
require "net/http"

class QuoteCatalog
  class Unavailable < StandardError; end

  STOREFRONT = "https://www.sherpaholidays.com".freeze
  COMPARISON_FIELDS = %w[trip_id shopify_product_id departure_id price_minor price_from price_source price_note included itinerary url].freeze

  def self.products
    Rails.cache.fetch("quote-catalog/product-handles", expires_in: 5.minutes) do
      JSON.parse(new.send(:get, "/products.json?limit=250")).fetch("products")
        .map { |product| product.slice("id", "handle", "title") }
    end
  rescue JSON::ParserError, KeyError => error
    raise Unavailable, "The published trip list could not be read (#{error.class})."
  end

  def self.storefront_trip(product_id: nil, handle: nil)
    product = products.find { |item| product_id ? item.fetch("id").to_s == product_id.to_s : item.fetch("handle") == handle }
    raise Unavailable, "This trip is not available on the published storefront." unless product

    PerfectBook::Trip.new(name: product.fetch("title"), shopify_product_id: product.fetch("id").to_s, active: true)
  end

  def self.snapshot(trip:, departure: nil)
    new.snapshot(trip: trip, departure: departure)
  end

  def snapshot(trip:, departure: nil)
    return nil unless trip

    result = { "trip_id" => trip.perfectbook_id, "departure_id" => departure&.perfectbook_id,
      "shopify_product_id" => trip.shopify_product_id.to_s.split("/").last.presence }
    if trip.shopify_product_id.present?
      product_id = trip.shopify_product_id.to_s.split("/").last
      products = self.class.products
      product = products.find { |item| item.fetch("id").to_s == product_id }
      raise Unavailable, "This trip is not available on the published storefront." unless product

      path = "/products/#{product.fetch('handle')}"
      document = Nokogiri::HTML(get(path))
      itinerary = panel_text(document, /\Afull itinerary\z/i)
      included = panel_text(document, /\Ainclusions\s*&\s*exclusions\z/i)
      if itinerary.blank? || included.blank?
        raise Unavailable, "The storefront itinerary or inclusions could not be read. Try loading published details again before sending."
      end

      trip_data = document.css('script[type="application/ld+json"]').flat_map do |node|
        data = JSON.parse(node.text)
        data.is_a?(Hash) ? [ data, *Array(data["@graph"]) ] : Array(data)
      end.find { |data| data.is_a?(Hash) && Array(data["@type"]).include?("TouristTrip") }
      offers = Array.wrap(trip_data&.fetch("offers", nil)).select { |offer| offer.is_a?(Hash) && !offer["name"].to_s.match?(/deposit/i) }
      priced_offers = offers.filter_map do |offer|
        specification = offer["priceSpecification"].is_a?(Hash) ? offer["priceSpecification"] : {}
        next unless (offer["priceCurrency"] || specification["priceCurrency"]) == "USD"

        price = QuoteMoney.parse((offer["price"] || specification["minPrice"]).to_s)
        [ price, offer ] if price&.positive?
      end
      price, offer = priced_offers.min_by(&:first)
      result.merge!("url" => "#{STOREFRONT}#{path}", "included" => included, "itinerary" => itinerary,
        "price_minor" => price, "price_from" => true, "price_source" => "SherpaHolidays storefront",
        "price_note" => offer&.fetch("description", nil),
        "checked_at" => Time.current.iso8601)
    end

    if departure&.price_per_person_minor.to_i.positive? && departure.currency == "USD"
      result.merge!("price_minor" => departure.price_per_person_minor, "price_from" => false,
        "price_source" => "PerfectBook departure", "price_note" => nil, "price_synced_at" => departure.synced_at&.iso8601)
    end
    result if result["url"].present? || result["price_minor"].present?
  rescue JSON::ParserError, KeyError, ArgumentError => error
    raise Unavailable, "The published trip details could not be read (#{error.class})."
  end

  def self.same_offer?(left, right)
    left&.slice(*COMPARISON_FIELDS) == right&.slice(*COMPARISON_FIELDS)
  end

  private

  def get(path)
    uri = URI("#{STOREFRONT}#{path}")
    response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 5, read_timeout: 10) do |http|
      accept = uri.path.end_with?(".json") ? "application/json" : "text/html"
      http.get(uri.request_uri, { "Accept" => accept, "User-Agent" => "PerfectCRM quote builder" })
    end
    raise Unavailable, "The storefront is unavailable. Try loading trip details again." unless response.is_a?(Net::HTTPSuccess)

    response.body
  rescue IOError, SystemCallError, Timeout::Error, SocketError, OpenSSL::SSL::SSLError, Net::HTTPBadResponse => error
    raise Unavailable, "The storefront is unavailable (#{error.class}). Try loading trip details again."
  end

  def panel_text(document, label)
    tab = document.css('[role="tab"]').find { |node| node.text.strip.match?(label) }
    return unless tab

    panel = document.at_xpath("//*[@id=$panel_id]", nil, { panel_id: tab["aria-controls"].to_s })
    return unless panel

    panel.css("script, style").remove
    panel.css("p, li, h2, h3, h4").map { |node| node.text.gsub(/[[:space:]]+/, " ").strip }.reject(&:blank?).join("\n\n")
  end
end
