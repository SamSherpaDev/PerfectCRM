require "application_system_test_case"
require_relative "../support/google_sign_in_test_helper"

# The captain builds quotes from his phone: the builder stacks with a docked
# total, and the client accepts with one tap on their own phone.
class QuotesSystemTest < ApplicationSystemTestCase
  include GoogleSignInTestHelper

  setup do
    OmniAuth.config.mock_auth[:google_oauth2] = OmniAuth::AuthHash.new(
      provider: "google_oauth2", uid: "google-captain",
      extra: { id_token: JWT.encode(@claims, @key, "RS256") }
    )
    Google::Auth::IDTokens.stub(:oidc_key_source, @source) do
      visit "/auth/google_oauth2/callback"
      assert_selector "h1", text: "Today"
    end
    page.current_window.resize_to(390, 844)
  end

  test "build a quote from the catalog and send it at phone width" do
    client = Client.create!(name: "Maya Gurung", email: "maya@example.com")
    PerfectBook::Trip.create!(perfectbook_id: 42, name: "Everest trek", active: true, synced_at: Time.current)
    PerfectBook::Departure.create!(perfectbook_id: 43, perfectbook_trip_id: 42,
      trip_name: "Everest trek", place: "Lukla", start_date: Date.new(2027, 5, 4),
      end_date: Date.new(2027, 5, 18), available_seats: 6, synced_at: Time.current)

    visit new_quote_path(client_id: client.id)
    assert_selector "h1", text: "New quote"
    assert_no_overflow("builder before trip")

    select "Everest trek", from: "Trip"
    assert_text "6 seats left"
    choose "4 May – 18 May 2027"
    assert_selector "#catalog-picker input[name='departure_id']:checked"
    assert_no_overflow("builder with departures")

    assert_selector "[data-line-row]", count: 4
    within(all("[data-line-row]").first) do
      fill_in "Each ($)", with: "1500"
    end
    click_button "Add line"
    assert_selector "[data-line-row]", count: 5
    within(all("[data-line-row]").last) do
      fill_in "Description", with: "Permits"
      fill_in "Each ($)", with: "50"
    end
    fill_in "Note", with: "Held two seats for you."
    assert_no_overflow("builder with lines")
    dimensions = all("[data-line-row]").last.evaluate_script(<<~JS)
      (() => {
        const description = this.querySelector("input[data-description]").getBoundingClientRect()
        const price = this.querySelector("input[data-each]").getBoundingClientRect()
        const quantity = this.querySelector("input[data-qty]").getBoundingClientRect()
        const remove = this.querySelector("button").getBoundingClientRect()
        return { descriptionWidth: description.width, descriptionBottom: description.bottom,
          priceTop: price.top, priceWidth: price.width, quantityTop: quantity.top,
          removeWidth: remove.width, removeHeight: remove.height }
      })()
    JS
    assert_operator dimensions["descriptionWidth"], :>=, 250
    assert_operator dimensions["priceWidth"], :>=, 70
    assert_operator dimensions["descriptionBottom"], :<=, dimensions["priceTop"]
    assert_in_delta dimensions["priceTop"], dimensions["quantityTop"], 1
    assert_operator dimensions["removeWidth"], :>=, 44
    assert_operator dimensions["removeHeight"], :>=, 44

    click_button "Send quote", match: :first
    assert_text "Quote sent"
    assert_no_overflow("quote page")
    quote = Quote.order(:created_at).last
    assert_equal "sent", quote.status
    assert_equal 2, quote.lines.count
    assert_equal 305_000, quote.subtotal_minor
  end

  test "client accepts from the public page at phone width" do
    client = Client.create!(name: "Maya Gurung", email: "maya@example.com")
    quote = Quote.create!(client: client, status: "sent", sent_at: 1.hour.ago,
      trip_name: "Everest trek", party_size: 2, valid_until: Date.current + 14,
      included: "Guides, lodges, permits.")
    quote.lines.create!(kind: "trip", description: "Everest trek", quantity: 2, unit_dollars: "1500.00")

    visit public_quote_path(quote.accept_token)
    assert_text "Your quote is ready"
    assert_text "$3,000.00"
    assert_no_overflow("accept page")

    click_button "Accept this quote"
    assert_text "Accepted"
    assert_no_overflow("accepted page")
    assert_equal "accepted", quote.reload.status

    visit quote_path(quote)
    assert_text "Create booking in PerfectBook"
    assert_text "Details to copy"
    assert_no_overflow("intake panel")
  end

  private

  def assert_no_overflow(context)
    width = page.evaluate_script("document.documentElement.scrollWidth")
    assert_operator width, :<=, 390, "#{context} overflows a 390px viewport (#{width}px)"
  end
end
