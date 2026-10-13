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
    @source = { "trip_name" => "Example trek", "trip_id" => 42, "shopify_product_id" => "123", "departure_id" => nil, "price_minor" => 397_500, "price_from" => true,
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
    source = @source.merge("trip_name" => "Private journey", "trip_id" => nil, "shopify_product_id" => "789")
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

  test "loading current details replaces source fields and preserves personal adjustments" do
    quote = sourced_quote
    new_source = @source.merge("price_minor" => 410_000, "itinerary" => "Day 1 | Updated route", "included" => "Updated inclusions")
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

  test "sending uses the reviewed draft when storefront details change" do
    quote = sourced_quote
    changed = @source.merge("price_minor" => 410_000, "itinerary" => "Changed route")
    QuoteCatalog.stub(:snapshot, changed) do
      assert_enqueued_emails(1) { post send_quote_quote_path(quote) }
    end
    assert_redirected_to quote_path(quote)
    assert_equal "sent", quote.reload.status
    assert_equal @source, quote.catalog_snapshot
    assert_equal @source, quote.terms_bundle["catalog_snapshot"]
    assert_equal @source["itinerary"], quote.itinerary
  end

  test "sending needs no storefront access including for trips without a mirror" do
    quote = sourced_quote
    quote.update!(perfectbook_trip_id: nil, shopify_product_id: "123")
    unavailable = ->(*, **) { flunk "Sending must not access the storefront" }
    QuoteCatalog.stub(:snapshot, unavailable) do
      QuoteCatalog.stub(:products, unavailable) do
        assert_enqueued_emails(1) { post send_quote_quote_path(quote) }
      end
    end
    assert_redirected_to quote_path(quote)
    assert_equal "sent", quote.reload.status
    assert_equal @source, quote.terms_bundle["catalog_snapshot"]
  end

  test "a priced mirror departure can send without a current snapshot" do
    @trip.update!(shopify_product_id: nil)
    departure = PerfectBook::Departure.create!(perfectbook_id: 43, perfectbook_trip_id: 42,
      start_date: Date.current + 30, end_date: Date.current + 40, currency: "USD", price_per_person_minor: 410_000, synced_at: Time.current)
    quote = sourced_quote
    quote.update!(catalog_snapshot: nil, perfectbook_departure_id: departure.perfectbook_id)
    assert_enqueued_emails(1) { post send_quote_quote_path(quote) }
    assert_redirected_to quote_path(quote)
    assert_equal "sent", quote.reload.status
    assert_nil quote.catalog_snapshot
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
    assert_not_includes response.body, "Published trip price"
    assert_not_includes response.body, "From $3,975.00 per person"
    assert_includes response.body, "$11,965.00"
  end

  test "explicit reload clears absent source fields across storefront mirror and custom selections" do
    other_trip = PerfectBook::Trip.create!(perfectbook_id: 99, name: "Other trek", active: true, synced_at: Time.current)
    storefront_trip = PerfectBook::Trip.create!(perfectbook_id: 100, name: "Request-only trek", active: true,
      shopify_product_id: "789", synced_at: Time.current)
    [ [ storefront_trip, @source.except("price_minor") ], [ other_trip, { "price_minor" => 210_000 } ],
      [ other_trip, nil ] ].each do |selected_trip, replacement|
      quote = sourced_quote
      quote.update!(included: "Previous trip inclusions", deposit_minor: 0)
      quote.lines.create!(kind: "departure", description: "Previous departure", quantity: 1, unit_minor: 123_000)
      source = replacement&.merge("trip_id" => selected_trip.perfectbook_id, "shopify_product_id" => selected_trip.shopify_product_id)
      QuoteCatalog.stub(:snapshot, source) do
        patch quote_path(quote), params: { load_trip_source: "1", quote: { perfectbook_trip_id: selected_trip.perfectbook_id } }
      end
      assert_redirected_to edit_quote_path(quote)
      quote.reload
      source ? assert_equal(source, quote.catalog_snapshot) : assert_nil(quote.catalog_snapshot)
      assert_equal source.to_h["included"].to_s, quote.included.to_s
      assert_equal source.to_h["itinerary"].to_s, quote.itinerary.to_s
      quote.lines.where(kind: "trip").each { |line| assert_equal source.to_h["price_minor"].to_i, line.unit_minor }
      assert_equal 2, quote.lines.where(kind: "trip").count
      assert_equal 4_000, quote.lines.find_by!(kind: "custom").unit_minor
      assert_equal "Owner note", quote.notes
    end
    quote = sourced_quote
    quote.update!(deposit_minor: 0)
    patch quote_path(quote), params: { load_trip_source: "1", quote: { perfectbook_trip_id: "" } }
    assert_redirected_to edit_quote_path(quote)
    assert_nil quote.reload.catalog_snapshot
    assert_nil quote.itinerary
    assert_nil quote.included
    assert_equal 0, quote.lines.find_by!(description: "Example trek").unit_minor
    assert_equal 4_000, quote.lines.find_by!(description: "Extra night").unit_minor
    assert_equal "Owner note", quote.notes
  end

  test "edit and send uses the saved storefront selection during outage or product removal" do
    [ -> { raise QuoteCatalog::Unavailable, "Storefront unavailable" }, -> { [] } ].each do |products|
      quote = sourced_quote
      source = @source.merge("trip_id" => nil)
      quote.update!(perfectbook_trip_id: nil, shopify_product_id: "123", catalog_snapshot: source)
      QuoteCatalog.stub(:products, [ { "id" => 123, "handle" => "example", "title" => "Example trek" } ]) do
        get edit_quote_path(quote)
      end
      assert_response :success
      token = css_select("input[name='catalog_source_token']").first["value"]
      QuoteCatalog.stub(:products, products) do
        QuoteCatalog.stub(:snapshot, ->(**) { flunk "Sending must not reload the source" }) do
          assert_enqueued_emails(1) do
            patch quote_path(quote), params: { send_now: "1", catalog_source_token: token,
              quote: { perfectbook_trip_id: "shopify:123", notes: "Reviewed personal note" } }
          end
        end
      end
      assert_redirected_to quote_path(quote)
      assert_equal "sent", quote.reload.status
      assert_equal source, quote.terms_bundle["catalog_snapshot"]
      assert_equal "Reviewed personal note", quote.notes
    end
  end

  test "new form save and send uses signed storefront details during outage or product removal" do
    [ -> { raise QuoteCatalog::Unavailable, "Storefront unavailable" }, -> { [] } ].each do |products|
      source = @source.merge("trip_id" => nil)
      QuoteCatalog.stub(:products, [ { "id" => 123, "handle" => "example", "title" => "Example trek" } ]) do
        QuoteCatalog.stub(:snapshot, source) do
          get new_quote_path(lead_id: @lead.id, storefront: "1", trip_id: "shopify:123")
        end
      end
      assert_response :success
      token = css_select("input[name='catalog_source_token']").first["value"]
      trip_name = css_select("input[name='quote[trip_name]']").first["value"]
      template = sourced_quote
      attributes = template.attributes.slice("party_size", "valid_until", "departure_start_on", "departure_end_on",
        "journey_kind", "local_operator", "trip_differences", "disclosure_details", "balance_due_on", "included")
      attributes.merge!("perfectbook_trip_id" => "", "shopify_product_id" => "123", "trip_name" => trip_name,
        "itinerary" => "Owner-reviewed itinerary", "deposit_dollars" => "12600.00",
        "lines_attributes" => { "0" => { "kind" => "trip", "description" => trip_name, "quantity" => 3, "unit_dollars" => "4200" } })
      QuoteCatalog.stub(:products, products) do
        QuoteCatalog.stub(:snapshot, ->(**) { flunk "Sending must not reload the source" }) do
          assert_enqueued_emails(1) do
            post quotes_path, params: { lead_id: @lead.id, send_now: "1", catalog_source_token: token, quote: attributes }
          end
        end
      end
      quote = Quote.order(:id).last
      assert_redirected_to quote_path(quote)
      assert_equal "sent", quote.status
      assert_equal source, quote.terms_bundle["catalog_snapshot"]
      assert_equal "Owner-reviewed itinerary", quote.itinerary
      assert_equal 420_000, quote.lines.first.unit_minor
    end
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
