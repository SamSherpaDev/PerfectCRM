require "application_system_test_case"
require "net/http"
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

    Capybara.using_session(:traveler) do
      page.current_window.resize_to(390, 844)
      visit public_quote_path(quote.accept_token)
      assert_text "Your quote is ready"
      assert_text "$3,000.00"
      assert_no_overflow("accept page")

      click_button "Accept this quote"
      assert_text "Accepted"
      assert_no_overflow("accepted page")
      assert_equal "accepted", quote.reload.status
    end

    visit quote_path(quote)
    assert_text "Create booking in PerfectBook"
    assert_text "Details to copy"
    page.scroll_to(find("#intake-heading"), align: :top)
    assert_no_overflow("intake panel")
    pdf_url = URI.join(page.current_url, find_link("PDF")[:href])
    request = Net::HTTP::Get.new(pdf_url)
    request["Cookie"] = page.driver.browser.manage.all_cookies.map { |cookie| "#{cookie[:name]}=#{cookie[:value]}" }.join("; ")
    response = Net::HTTP.start(pdf_url.host, pdf_url.port) { |http| http.request(request) }
    assert_equal "200", response.code
    assert_equal "application/pdf", response["Content-Type"]
    assert response.body.start_with?("%PDF"), "The download must return a PDF"
    if ENV["QUOTE_EVIDENCE_DIR"].present?
      File.binwrite(File.join(ENV.fetch("QUOTE_EVIDENCE_DIR"), "accepted-quote.pdf"), response.body)
    end
  end

  test "switching to a trip without departures clears the old departure" do
    client = Client.create!(name: "Maya", email: "maya@example.com")
    PerfectBook::Trip.create!(perfectbook_id: 42, name: "Everest", active: true, synced_at: Time.current)
    PerfectBook::Trip.create!(perfectbook_id: 44, name: "Annapurna", active: true, synced_at: Time.current)
    PerfectBook::Departure.create!(perfectbook_id: 43, perfectbook_trip_id: 42,
      start_date: Date.new(2027, 5, 4), end_date: Date.new(2027, 5, 18), synced_at: Time.current)
    visit new_quote_path(client_id: client.id, trip_id: 42, departure_id: 43)
    select "Annapurna", from: "Trip"
    assert_text "No upcoming departures"
    within(all("[data-line-row]").first) do
      assert_field "Description", with: "Annapurna"
      fill_in "Each ($)", with: "1500"
    end
    click_button "Save draft"
    assert_text "Quote saved as a draft"
    quote = Quote.order(:id).last
    assert_equal 44, quote.perfectbook_trip_id
    assert_nil quote.perfectbook_departure_id
    assert_equal "Annapurna", quote.lines.first.snapshot_trip_name
  end

  test "captain reads booking balances and opens a contextual document nudge" do
    client = Client.create!(name: "Maya Gurung", email: "maya@example.com", perfectbook_contact_id: 7)
    Template.create!(name: "Documents", purpose: :document_request,
      subject: "Documents for {{trip}}", body: "Hi {{full_name}}, {{departure_dates}}: {{missing_documents}}")
    PerfectBook::Booking.create!(perfectbook_id: 11, perfectbook_contact_id: 7,
      ref: "BK-11", status: "deposit_received", trip_name: "Everest trek",
      start_date: Date.new(2027, 5, 4), end_date: Date.new(2027, 5, 18),
      party_size: 2, total_minor: 400_000, paid_minor: 100_000, balance_due_minor: 300_000,
      currency: "USD", invoice_badge: "sent", invoice_number: "SH-2027-0142",
      deep_link: "https://perfectbook.example.test/bookings/11", synced_at: Time.current)
    visit client_path(client)
    within("section[aria-labelledby='perfectbook-heading']") do
      assert_text "$4,000.00"
      assert_text "$1,000.00"
      assert_text "$3,000.00"
      assert_text "SH-2027-0142"
      assert_link "Open in PerfectBook", href: "https://perfectbook.example.test/bookings/11"
      assert_text "Document status arrives with the PerfectBook update"
    end
    page.scroll_to(find("section[aria-labelledby='perfectbook-heading']"), align: :top)
    assert_no_overflow("booking card")
    click_link "Nudge for missing documents"
    assert_field "To", with: "maya@example.com"
    body = find_field("Message").value
    %w[Maya Everest 2027 BK-11].each { |word| assert_includes body, word }
    assert_includes body, "Check missing documents in PerfectBook"
    assert_no_selector "button", text: "Send"
    assert_no_overflow("document nudge")
  end

  test "revision stays private until sent and duplicate retains its deposit" do
    client = Client.create!(name: "Maya Gurung", email: "maya@example.com")
    quote = Quote.create!(party_size: 2, client: client, status: "sent", sent_at: Time.current,
      trip_name: "Everest trek", valid_until: Date.current + 14)
    quote.lines.create!(kind: "custom", description: "Trek", quantity: 2, unit_dollars: "1500")
    quote.update!(deposit_dollars: "500")
    visit quote_path(quote)
    click_button "Duplicate"
    assert_text "Quote duplicated as"
    duplicate = Quote.order(:id).last
    assert_equal "draft", duplicate.status
    assert_equal 50_000, duplicate.deposit_minor
    assert_equal 300_000, duplicate.subtotal_minor
    visit quote_path(quote)
    click_button "New revision"
    assert_text "The old version keeps its history"
    revision = Quote.order(:id).last
    assert_equal "superseded", quote.reload.status
    visit public_quote_path(quote.accept_token)
    assert_text "A newer quote is on its way"
    assert_no_link "View the newer quote"
    assert_no_button "Accept this quote"
    assert_no_overflow("private revision notice")
    visit public_quote_path(revision.accept_token)
    assert_no_text "Trek"
    assert_no_button "Accept this quote"
    visit quote_path(revision)
    click_button "Send quote"
    assert_text "Quote sent"
    visit public_quote_path(quote.accept_token)
    click_link "View the newer quote"
    assert_text "$3,000.00"
    click_button "Accept this quote"
    assert_text "Accepted"
    visit quote_path(revision)
    assert_no_button "New revision"
    assert_text "Create booking in PerfectBook"
  end

  test "invalid money and blank saved descriptions preserve edits until corrected" do
    client = Client.create!(name: "Maya Gurung", email: "maya@example.com")
    quote = Quote.create!(party_size: 2, client: client, trip_name: "Everest trek", valid_until: Date.current + 14)
    line = quote.lines.create!(kind: "custom", description: "Original", quantity: 1, unit_dollars: "1500")
    visit edit_quote_path(quote)
    within(all("[data-line-row]").first) do
      fill_in "Description", with: ""
      fill_in "Each ($)", with: "1,600"
    end
    click_button "Send quote", match: :first
    assert_text "This quote needs attention"
    assert_field "Each ($)", with: "1,600"
    assert_equal "draft", quote.reload.status
    assert_equal 150_000, line.reload.unit_minor
    assert_no_overflow("invalid money retained")
    within(all("[data-line-row]").first) do
      fill_in "Each ($)", with: "1600"
    end
    click_button "Send quote", match: :first
    assert_text "Lines description can't be blank"
    within(all("[data-line-row]").first) { fill_in "Description", with: "Updated trek" }
    click_button "Send quote", match: :first
    assert_text "Quote sent"
    assert_equal 160_000, quote.reload.subtotal_minor
    assert_equal "Updated trek", line.reload.description
  end

  test "public visits count while expired and unknown links cannot accept" do
    client = Client.create!(name: "Maya Gurung", email: "maya@example.com")
    quote = Quote.create!(client: client, status: "sent", sent_at: Time.current,
      trip_name: "Everest trek", valid_until: Date.current + 14)
    quote.lines.create!(kind: "custom", description: "Trek", quantity: 1, unit_dollars: "1500")
    3.times do
      visit public_quote_path(quote.accept_token)
      assert_button "Accept this quote"
    end
    assert_equal 3, quote.reload.view_count
    quote.update!(valid_until: Date.current - 1)
    visit public_quote_path(quote.accept_token)
    assert_text "expired"
    assert_no_button "Accept this quote"
    assert_no_overflow("expired quote")
    visit public_quote_path("unknown-token")
    assert_no_text "Everest trek"
    assert_no_button "Accept this quote"
    assert_equal "viewed", quote.reload.status
  end

  test "required terms stay optional for drafts and show errors before sending" do
    client = Client.create!(name: "Maya", email: "maya@example.com")
    visit new_quote_path(client_id: client.id)
    assert_field "quote_valid_until", with: (Date.current + 14).iso8601
    within(all("[data-line-row]").first) do
      fill_in "Description", with: "Trek"
      fill_in "Each ($)", with: "1500"
    end
    fill_in "quote_party_size", with: ""
    fill_in "quote_valid_until", with: ""
    click_button "Send quote", match: :first
    assert_text "Party size can't be blank"
    assert_text "Valid until can't be blank"
    assert_equal "draft", Quote.order(:id).last.status
    click_button "Save draft"
    assert_text "Quote saved"
  end

  test "catalog changes preserve entered quote details" do
    client = Client.create!(name: "Maya", email: "maya@example.com")
    PerfectBook::Trip.create!(perfectbook_id: 42, name: "Everest", active: true, synced_at: Time.current)
    PerfectBook::Trip.create!(perfectbook_id: 44, name: "Annapurna", active: true, synced_at: Time.current)
    PerfectBook::Departure.create!(perfectbook_id: 45, perfectbook_trip_id: 44,
      start_date: Date.new(2027, 5, 4), end_date: Date.new(2027, 5, 18), synced_at: Time.current)
    visit new_quote_path(client_id: client.id, trip_id: 42)
    within(all("[data-line-row]").first) do
      fill_in "Each ($)", with: "1600"
      fill_in "Qty", with: "3"
    end
    click_button "Add line"
    within(all("[data-line-row]").last) do
      fill_in "Description", with: "Extra nights"
      fill_in "Each ($)", with: "75"
    end
    fill_in "Note", with: "Keep these details"
    fill_in "What is included", with: "Guide only"
    fill_in "quote_party_size", with: "3"
    fill_in "quote_deposit_dollars", with: "200"
    select "Annapurna", from: "Trip"
    assert_field "Note", with: "Keep these details"
    within(all("[data-line-row]").first) do
      assert_field "Description", with: "Annapurna"
      fill_in "Description", with: "Annapurna with private guide"
    end
    choose "4 May – 18 May 2027"
    within(all("[data-line-row]").first) do
      assert_field "Description", with: "Annapurna with private guide"
    end
    assert_field "Note", with: "Keep these details"
    assert_field "What is included", with: "Guide only"
    assert_field "quote_deposit_dollars", with: "200.00"
    within(all("[data-line-row]").first) do
      assert_field "Each ($)", with: "1600.00"
      assert_field "Qty", with: "3"
    end
    assert_field "Description", with: "Extra nights"
    assert_no_overflow("catalog changes preserve inputs")
    click_button "Save draft"
    assert_text "Quote saved as a draft"
    quote = Quote.order(:id).last
    assert_equal "Annapurna with private guide", quote.lines.find_by!(kind: "departure").description
    assert_equal 45, quote.perfectbook_departure_id
    assert_equal 487500, quote.subtotal_minor
    assert_equal "Keep these details", quote.notes
  end

  test "remembered inclusions load on first selection and preserve later edits" do
    client = Client.create!(name: "Maya", email: "maya@example.com")
    PerfectBook::Trip.create!(perfectbook_id: 42, name: "Everest", active: true, synced_at: Time.current)
    PerfectBook::Trip.create!(perfectbook_id: 44, name: "Annapurna", active: true, synced_at: Time.current)
    QuoteTripPreference.create!(perfectbook_trip_id: 42, included: "Everest guide and permits")
    QuoteTripPreference.create!(perfectbook_trip_id: 44, included: "Annapurna lodges")
    visit new_quote_path(client_id: client.id)
    select "Everest", from: "Trip"
    assert_field "What is included", with: "Everest guide and permits"
    select "Annapurna", from: "Trip"
    assert_field "What is included", with: "Everest guide and permits"
    fill_in "What is included", with: "Private guide only"
    select "Everest", from: "Trip"
    assert_field "What is included", with: "Private guide only"
    fill_in "What is included", with: ""
    select "Annapurna", from: "Trip"
    assert_field "What is included", with: ""

    visit new_quote_path(client_id: client.id)
    fill_in "What is included", with: "Custom inclusions before choosing"
    select "Everest", from: "Trip"
    assert_field "What is included", with: "Custom inclusions before choosing"

    visit new_quote_path(client_id: client.id)
    fill_in "What is included", with: "Changed my mind"
    fill_in "What is included", with: ""
    select "Everest", from: "Trip"
    assert_field "What is included", with: ""
  end

  test "departure selection refreshes untouched prices and preserves edited prices" do
    client = Client.create!(name: "Maya", email: "maya@example.com")
    PerfectBook::Trip.create!(perfectbook_id: 42, name: "Everest", active: true, synced_at: Time.current)
    PerfectBook::Departure.create!(perfectbook_id: 43, perfectbook_trip_id: 42,
      start_date: Date.new(2027, 5, 4), end_date: Date.new(2027, 5, 18), synced_at: Time.current)
    PerfectBook::Departure.create!(perfectbook_id: 44, perfectbook_trip_id: 42,
      start_date: Date.new(2027, 6, 4), end_date: Date.new(2027, 6, 18), synced_at: Time.current)
    previous = Quote.create!(client: client, status: "accepted", sent_at: 2.days.ago, sent_by_email: User.find_by!(google_sub: "google-captain").email)
    previous.lines.create!(kind: "departure", description: "Everest", quantity: 1, unit_minor: 200_000,
      perfectbook_trip_id: 42, perfectbook_departure_id: 43)
    recent = Quote.create!(client: client, status: "sent", sent_at: 1.day.ago, sent_by_email: User.find_by!(google_sub: "google-captain").email)
    recent.lines.create!(kind: "trip", description: "Everest", quantity: 1, unit_minor: 300_000, perfectbook_trip_id: 42)

    visit new_quote_path(client_id: client.id)
    select "Everest", from: "Trip"
    assert_text "Prefilled from your last quote"
    assert_selector "[data-line-row]:first-child input[data-each][value='3000.00']"
    choose "4 May – 18 May 2027"
    assert_selector "[data-line-row]:first-child input[data-each][value='2000.00']"

    choose "4 Jun – 18 Jun 2027"
    assert_selector "input[name='departure_id'][value='44']:checked"
    assert_selector "input[data-description][value='Everest - 4 Jun – 18 Jun 2027']"
    within(all("[data-line-row]").first) do
      assert_field "Each ($)", with: "3000.00"
      fill_in "Each ($)", with: "2500"
    end
    choose "4 May – 18 May 2027"
    assert_selector "[data-line-row]:first-child input[data-each][value='2500.00']"
    choose "4 Jun – 18 Jun 2027"
    assert_selector "input[name='departure_id'][value='44']:checked"
    assert_selector "input[data-description][value='Everest - 4 Jun – 18 Jun 2027']"
    within(all("[data-line-row]").first) do
      assert_field "Each ($)", with: "2500.00"
      fill_in "Each ($)", with: ""
    end
    choose "4 May – 18 May 2027"
    assert_selector "input[data-description][value='Everest - 4 May – 18 May 2027']"
    assert_selector "[data-line-row]:first-child input[data-each][value='0.00']"
    click_button "Save draft"
    assert_text "Quote saved as a draft"
    assert_equal 0, Quote.order(:id).last.lines.find_by!(kind: "departure").unit_minor
  end

  private

  def assert_no_overflow(context)
    width = page.evaluate_script("document.documentElement.scrollWidth")
    assert_operator width, :<=, 390, "#{context} overflows a 390px viewport (#{width}px)"
    if ENV["QUOTE_EVIDENCE_DIR"].present?
      page.save_screenshot(File.join(ENV.fetch("QUOTE_EVIDENCE_DIR"), "#{context.parameterize}.png"))
    end
  end
end
