require "test_helper"
require_relative "../support/google_sign_in_test_helper"
require_relative "../support/quote_terms_test_helper"

class QuoteItinerariesRequestsTest < ActionDispatch::IntegrationTest
  include GoogleSignInTestHelper
  include QuoteTermsTestHelper

  setup do
    sign_in
    @lead = Lead.create!(name: "Synthetic traveler", email: "traveler@example.test", party_size: 3, trip_title: "Example trek")
    @trip = PerfectBook::Trip.create!(perfectbook_id: 42, name: "Example trek", active: true, shopify_product_id: "123", synced_at: Time.current)
    @source = { "trip_id" => 42, "shopify_product_id" => "123", "departure_id" => nil, "price_minor" => 397_500, "price_from" => true,
      "price_source" => "SherpaHolidays storefront", "url" => "https://www.sherpaholidays.com/products/example",
      "checked_at" => Time.current.iso8601, "included" => "Guide and lodges. Flights excluded.",
      "itinerary" => "Day 1 | Kathmandu\nMeet your guide.\n\nDay 2 | Walk to the lodge." }
  end

  test "inquiry builder starts with its trip and group and current published details without sending" do
    earlier = Quote.create!(lead: @lead, status: "sent", sent_at: 1.day.ago, sent_by_email: "captain@gmail.com")
    earlier.lines.create!(kind: "trip", perfectbook_trip_id: 42, description: "Previous offer", quantity: 3, unit_minor: 300_000)
    assert_no_enqueued_emails do
      assert_no_difference "Quote.count" do
        QuoteCatalog.stub(:snapshot, @source) { get new_quote_path(lead_id: @lead.id) }
      end
    end
    assert_response :success
    assert_select "option[selected][value='42']", text: "Example trek"
    assert_select "input[name='quote[party_size]'][value='3']"
    assert_select "input[data-qty][value='3']"
    assert_select "input[data-each][value='3975.00']"
    assert_select "textarea[name='quote[itinerary]']", text: @source["itinerary"]
    assert_select "textarea[name='quote[included]']", text: @source["included"]
    assert_includes response.body, "From $3,975.00 per person"
    assert_not_includes response.body, "Prefilled from your last quote"
  end

  test "catalog preview preserves personal edits including cleared content and price" do
    QuoteCatalog.stub(:snapshot, @source) do
      post preview_quotes_path, params: { lead_id: @lead.id, trip_id: 42,
        included_edited: "1", itinerary_edited: "1", quote: {
          itinerary: "", included: "Owner inclusions", notes: "A personal note", party_size: 4,
          lines_attributes: { "0" => { kind: "trip", description: "Tailored trek", quantity: 4, unit_dollars: "4200", price_edited: "1" } }
        } }
    end
    assert_response :success
    assert_select "textarea[name='quote[itinerary]']", text: ""
    assert_select "textarea[name='quote[included]']", text: "Owner inclusions"
    assert_select "input[data-each][value='4200.00']"
  end

  test "catalog preview accepts the builders CSRF token with forgery protection enabled" do
    original_protection = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
    QuoteCatalog.stub(:snapshot, @source) do
      get new_quote_path(lead_id: @lead.id)
      token = css_select("#quote-builder-form input[name='authenticity_token']").first["value"]
      QuoteCatalog.stub(:products, []) do
        post preview_quotes_path, params: { authenticity_token: token, lead_id: @lead.id, storefront: "1", trip_id: 42 }
      end
    end
    assert_response :success
    assert_select "textarea[name='quote[itinerary]']", text: @source["itinerary"]
  ensure
    ActionController::Base.allow_forgery_protection = original_protection
  end

  test "the owners selected trip interest takes precedence over the website trip title" do
    @lead.update!(trip_interest: "Zebra trek")
    PerfectBook::Trip.create!(perfectbook_id: 44, name: "Zebra trek", active: true, synced_at: Time.current)
    QuoteCatalog.stub(:snapshot, nil) { get new_quote_path(lead_id: @lead.id) }
    assert_response :success
    assert_select "select[name='trip_id'] option[selected][value='44']", text: "Zebra trek"
  end

  test "published trips without a PerfectBook mirror can be selected saved and edited with flexible dates" do
    products = [ { "id" => 123, "handle" => "example", "title" => "Example trek" },
      { "id" => 789, "handle" => "private", "title" => "Private journey" } ]
    source = @source.merge("trip_id" => nil, "shopify_product_id" => "789")
    QuoteCatalog.stub(:products, products) do
      QuoteCatalog.stub(:snapshot, source) do
        get new_quote_path(lead_id: @lead.id, storefront: "1", trip_id: "shopify:789")
        assert_response :success
        assert_select "select[name='trip_id'] option[value='42']", count: 1
        assert_select "select[name='trip_id'] option[value='shopify:123']", count: 0
        assert_select "select[name='trip_id'] option[selected][value='shopify:789']", text: "Private journey"
        assert_select "input[name='quote[shopify_product_id]'][value='789']"
        assert_select "input[name='quote[departure_start_on]']"
        token = css_select("input[name='catalog_source_token']").first["value"]
        assert_no_enqueued_emails do
          assert_no_difference "PerfectBook::Trip.count" do
            post quotes_path, params: { lead_id: @lead.id, catalog_source_token: token, quote: {
              shopify_product_id: "789", perfectbook_trip_id: "", party_size: 3, itinerary: source["itinerary"],
              lines_attributes: { "0" => { kind: "trip", description: "Private journey", quantity: 3, unit_dollars: "3975" } }
            } }
          end
        end
        quote = Quote.order(:id).last
        assert_redirected_to quote_path(quote)
        assert_nil quote.perfectbook_trip_id
        assert_equal "789", quote.shopify_product_id
        assert_equal "Private journey", quote.trip_name
        assert_equal source, quote.catalog_snapshot
        assert_equal "trip", quote.lines.first.kind
        get edit_quote_path(quote)
        assert_response :success
        assert_select "select[name='quote[perfectbook_trip_id]'] option[selected][value='shopify:789']"
        patch quote_path(quote), params: { quote: { perfectbook_trip_id: "", trip_name: "Custom route" } }
        assert_redirected_to quote_path(quote)
        assert_nil quote.reload.shopify_product_id
        assert_nil quote.catalog_snapshot
        assert_equal "Custom route", quote.trip_name
      end
    end
  end

  test "saved draft retains the signed source and edited itinerary on its inquiry with PDF available" do
    assert_no_enqueued_emails do
      post quotes_path, params: { lead_id: @lead.id, catalog_source_token: source_token, quote: {
        perfectbook_trip_id: 42, party_size: 3, itinerary: "Day 1 | Tailored arrival", included: "Tailored inclusions",
        lines_attributes: { "0" => { kind: "trip", description: "Example trek", quantity: 3, unit_dollars: "3975" } }
      } }
    end
    quote = Quote.order(:id).last
    assert_redirected_to quote_path(quote)
    assert_equal @lead, quote.lead
    assert_equal "draft", quote.status
    assert_equal @source, quote.catalog_snapshot
    assert_equal "Day 1 | Tailored arrival", quote.itinerary
    get quote_path(quote)
    assert_select "a[href=?]", quote_path(quote, format: :pdf), text: "PDF"
    assert_includes response.body, "Day 1 | Tailored arrival"
    get lead_path(@lead)
    assert_select "a[href=?]", quote_path(quote), text: quote.reference
  end

  test "forged source token cannot create a quote" do
    assert_no_difference "Quote.count" do
      post quotes_path, params: { lead_id: @lead.id, catalog_source_token: "forged", quote: { perfectbook_trip_id: 42 } }
    end
    assert_response :unprocessable_entity
    assert_includes response.body, "Trip source could not be verified"
  end

  test "sending rechecks published details and requires loading and reviewing changed source" do
    quote = sourced_quote
    new_source = @source.merge("price_minor" => 410_000, "itinerary" => "Day 1 | Updated route", "included" => "Updated inclusions")
    assert_no_enqueued_emails do
      QuoteCatalog.stub(:snapshot, new_source) { post send_quote_quote_path(quote) }
    end
    assert_response :unprocessable_entity
    assert_includes response.body, "Trip details or prices have changed"
    assert_equal "draft", quote.reload.status
    assert_equal @source, quote.catalog_snapshot
    assert_equal "Owner note", quote.notes

    assert_no_enqueued_emails do
      QuoteCatalog.stub(:snapshot, new_source) do
        patch quote_path(quote), params: { load_trip_source: "1", quote: { notes: "Owner note" } }
      end
    end
    assert_redirected_to edit_quote_path(quote)
    assert_equal new_source, quote.reload.catalog_snapshot
    assert_equal "Day 1 | Updated route", quote.itinerary
    assert_equal "Updated inclusions", quote.included
    assert_equal 410_000, quote.lines.find_by!(kind: "trip").unit_minor
    assert_equal 4_000, quote.lines.find_by!(kind: "custom").unit_minor
    assert_equal "Owner note", quote.notes

    complete_quote_terms(quote)
    QuoteCatalog.stub(:snapshot, new_source) { assert_enqueued_emails(1) { post send_quote_quote_path(quote) } }
    assert_equal "sent", quote.reload.status
    assert_equal new_source, quote.terms_bundle["catalog_snapshot"]
    assert_includes quote.terms_bundle["itinerary"], quote.itinerary
    post revise_quote_path(quote)
    revision = Quote.order(:id).last
    assert_equal quote, revision.parent
    assert_equal quote.itinerary, revision.itinerary
    assert_equal quote.catalog_snapshot, revision.catalog_snapshot
    assert_equal 2, revision.version
    assert_equal "draft", revision.status
  end

  test "storefront outage preserves a draft and sends no email" do
    quote = sourced_quote
    unavailable = ->(**) { raise QuoteCatalog::Unavailable, "Storefront unavailable" }
    assert_no_enqueued_emails do
      QuoteCatalog.stub(:snapshot, unavailable) { post send_quote_quote_path(quote) }
    end
    assert_response :unprocessable_entity
    assert_includes response.body, "Storefront unavailable"
    assert_equal "draft", quote.reload.status
  end

  test "a priced mirror departure requires its current snapshot even without a Shopify link" do
    @trip.update!(shopify_product_id: nil)
    departure = PerfectBook::Departure.create!(perfectbook_id: 43, perfectbook_trip_id: 42,
      start_date: Date.current + 30, end_date: Date.current + 40, currency: "USD", price_per_person_minor: 410_000, synced_at: Time.current)
    quote = sourced_quote
    quote.update!(catalog_snapshot: nil, perfectbook_departure_id: departure.perfectbook_id)
    assert_no_enqueued_emails { post send_quote_quote_path(quote) }
    assert_response :unprocessable_entity
    assert_equal "draft", quote.reload.status
    patch quote_path(quote), params: { load_trip_source: "1", quote: { notes: "Owner note" } }
    assert_redirected_to edit_quote_path(quote)
    assert_equal false, quote.reload.catalog_snapshot["price_from"]
    assert_equal 410_000, quote.lines.find_by!(kind: "departure").unit_minor
  end

  test "delivered itinerary and source cannot be changed and public page shows reviewed content" do
    quote = sourced_quote
    QuoteCatalog.stub(:snapshot, @source) { post send_quote_quote_path(quote) }
    assert_equal "sent", quote.reload.status
    original_itinerary = quote.itinerary
    assert_not quote.update(itinerary: "Changed after sending")
    quote.reload
    assert_not quote.update(catalog_snapshot: @source.merge("price_minor" => 1))
    quote.reload
    assert_equal @source, quote.catalog_snapshot
    assert_equal original_itinerary, quote.itinerary
    get public_quote_path(quote.accept_token)
    assert_includes response.body, "Day 2 | Walk to the lodge."
    assert_includes response.body, "From $3,975.00 per person"
  end

  private

  def source_token
    Rails.application.message_verifier(:quote_catalog).generate(@source, purpose: :quote_catalog)
  end

  def sourced_quote
    quote = Quote.new(lead: @lead, perfectbook_trip_id: 42, trip_name: @trip.name,
      party_size: 3, valid_until: Date.current + 14, catalog_snapshot: @source, itinerary: @source["itinerary"], notes: "Owner note")
    quote.lines.build(kind: "trip", description: "Example trek", quantity: 3, unit_minor: 397_500)
    quote.lines.build(kind: "custom", description: "Extra night", quantity: 1, unit_minor: 4_000)
    quote.save!
    complete_quote_terms(quote)
    quote
  end
end
