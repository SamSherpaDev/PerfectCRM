require "test_helper"
require_relative "../support/quote_terms_test_helper"
require_relative "../support/google_sign_in_test_helper"

class QuoteTermsRequestsTest < ActionDispatch::IntegrationTest
  include QuoteTermsTestHelper
  include GoogleSignInTestHelper

  setup do
    @client = Client.create!(name: "Synthetic Traveler", email: "traveler@example.com")
    @quote = Quote.create!(client: @client, party_size: 1, valid_until: Date.current + 14)
    @quote.lines.create!(description: "Synthetic itinerary", quantity: 1, unit_minor: 397_500)
    complete_quote_terms(@quote, days: 180)
    assert @quote.deliver!
  end

  test "public acceptance must confirm the exact delivered bundle" do
    get public_quote_path(@quote.accept_token)
    assert_select "input[name='terms_accepted'][required]"
    assert_select "input[name='bundle_sha256'][value=?]", @quote.terms_bundle_sha256
    assert_includes response.body, "45 days or fewer"
    assert_includes response.body, QuoteTerms::VERSION
    assert_no_enqueued_emails do
      post accept_public_quote_path(@quote.accept_token)
      post accept_public_quote_path(@quote.accept_token), params: { terms_accepted: "1", bundle_sha256: "stale" }
    end
    assert_equal "viewed", @quote.reload.status
    assert_enqueued_emails 1 do
      post accept_public_quote_path(@quote.accept_token), params: { terms_accepted: "1", bundle_sha256: @quote.terms_bundle_sha256 }
    end
    assert_equal QuoteTerms::VERSION, @quote.reload.accepted_terms_version
    assert_equal @quote.terms_bundle_sha256, @quote.accepted_bundle_sha256
  end

  test "public summary and download use the delivered wording while builder previews current text" do
    delivered = @quote.terms_bundle.fetch("if_things_go_wrong")
    QuoteTerms.stub(:if_things_go_wrong, "Future summary wording") do
      get public_quote_path(@quote.accept_token)
      assert_select "section[aria-labelledby='if-things-go-wrong-heading']" do
        assert_select "h2", "If things go wrong"
        assert_select "h3", count: 4
        assert_select "p", text: /we cover up to 2 extra nights while you wait/
      end
      assert_not_includes response.body, "Future summary wording"
      get public_quote_documents_path(@quote.accept_token)
      assert_equal delivered, JSON.parse(response.body).fetch("if_things_go_wrong")
      sign_in
      draft = @quote.duplicate!
      get edit_quote_path(draft)
      assert_response :success
      assert_select "details summary", "Preview If things go wrong"
      assert_select "section[aria-labelledby='if-things-go-wrong-heading'] p", "Future summary wording"
    end
  end

  test "documents download mail and PDF contain the same immutable texts" do
    get public_quote_documents_path(@quote.accept_token)
    assert_response :success
    assert_equal @quote.terms_bundle, response.parsed_body
    assert_equal "SH-TC-2026-10-14", response.parsed_body["terms_version"]
    assert_equal "SH-DISC-2026-10-14", response.parsed_body["disclosure_version"]
    delay_promise = "If weather delays your Lukla flight and you need to wait, we cover up to 2 extra nights while you wait, and more when the situation calls for it. Nights you choose to add, or a helicopter you choose instead of waiting, are your cost, quoted before anything is booked."
    %w[master_terms pre_payment_disclosure].each do |name|
      assert_includes response.parsed_body.fetch(name), delay_promise
      assert_not_includes response.parsed_body.fetch(name), "SherpaHolidays pays for the extra nights"
    end
    master = response.parsed_body.fetch("master_terms")
    assert_includes master, "An inquiry starts a conversation, not a booking. We reply within one business day. Before you pay,"
    assert_includes master, "Please contact us promptly with questions about your booking or a charge. We reply within one business day. We provide a substantive response to a written complaint within 14 business days. Contacting us"
    assert_not_includes master, "within 24 hours"
    email = QuoteMailer.quote_email(@quote)
    %w[master_terms pre_payment_disclosure trip_differences itinerary].each do |name|
      assert_equal @quote.terms_bundle.fetch(name), email.attachments["#{@quote.reference}-#{name}.txt"].decoded
    end
    pdf_text = PDF::Reader.new(StringIO.new(email.attachments["quote-#{@quote.reference}.pdf"].decoded)).pages.map(&:text).join
    assert_includes pdf_text, QuoteTerms::VERSION
    assert_includes pdf_text.gsub(/\s+/, " "), delay_promise
    assert_includes pdf_text, "45 days or fewer"
    assert_includes pdf_text, "Westfield National Insurance Company"
  end

  test "October 4 delivered documents keep their bytes and version through acceptance" do
    # Model a previously issued bundle, including its completed disclosure.
    bundle = @quote.terms_bundle.deep_dup
    bundle["terms_version"] = "SH-TC-2026-10-04"
    bundle["disclosure_version"] = "SH-DISC-2026-10-04"
    bundle["master_terms"] = Rails.root.join("config/booking_terms/SH-TC-2026-10-04/master-terms.md").read
      .sub("[verified operator legal name]", @quote.local_operator)
    bundle["pre_payment_disclosure"] = bundle.fetch("pre_payment_disclosure")
      .sub("SH-DISC-2026-10-14", "SH-DISC-2026-10-04")
      .sub("SH-TC-2026-10-14", "SH-TC-2026-10-04")
      .sub("we cover up to 2 extra nights while you wait, and more when the situation calls for it",
        "SherpaHolidays pays for the extra nights")
    bytes = JSON.generate(bundle)
    sha256 = Digest::SHA256.hexdigest(bytes)
    @quote.update_columns(terms_bundle: bundle, terms_bundle_sha256: sha256)

    get public_quote_documents_path(@quote.accept_token)
    assert_response :success
    assert_equal bytes, JSON.generate(response.parsed_body)
    email = QuoteMailer.quote_email(@quote.reload)
    %w[master_terms pre_payment_disclosure].each do |name|
      assert_equal bundle.fetch(name), email.attachments["#{@quote.reference}-#{name}.txt"].decoded
    end
    post accept_public_quote_path(@quote.accept_token), params: { terms_accepted: "1", bundle_sha256: sha256 }
    assert_equal "accepted", @quote.reload.status
    assert_equal "SH-TC-2026-10-04", @quote.accepted_terms_version
    assert_equal sha256, @quote.accepted_bundle_sha256
    assert_equal bundle, @quote.intake_details["terms_bundle"]
    get public_quote_documents_path(@quote.accept_token)
    assert_response :success
    assert_equal bytes, JSON.generate(response.parsed_body)
  end

  test "manual intake export contains accepted version bytes amounts and timestamp" do
    @quote.accept!(bundle_sha256: @quote.terms_bundle_sha256)
    sign_in
    get terms_intake_quote_path(@quote)
    assert_response :success
    assert_equal @quote.intake_details, response.parsed_body
    assert_equal @quote.terms_bundle, response.parsed_body["terms_bundle"]
    assert_equal 50_000, response.parsed_body["deposit_minor"]
    email = QuoteMailer.accepted_notice(@quote)
    assert_equal @quote.intake_details, JSON.parse(email.attachments["#{@quote.reference}-perfectbook-intake.json"].decoded)
  end

  test "builder posts structured disclosure without losing entries on catalog refresh" do
    sign_in
    get new_quote_path(client_id: @client.id)
    assert_select "textarea[name='quote[disclosure_details][security_evidence]']"
    details = @quote.disclosure_details
    post preview_quotes_path, params: { client_id: @client.id, quote: {
      journey_kind: "private", local_operator: "Synthetic Operator LLC", trip_differences: "None", disclosure_details: details
    } }
    assert_response :success
    assert_select "textarea[name='quote[disclosure_details][security_evidence]']", text: details["security_evidence"]
  end
  test "flexible catalog dates stay editable and survive creation and updates" do
    sign_in
    trip = PerfectBook::Trip.create!(perfectbook_id: 42, name: "Private trek", active: true, synced_at: Time.current)
    get new_quote_path(client_id: @client.id, trip_id: trip.perfectbook_id)
    assert_select "input[type=date][name='quote[departure_start_on]']"
    assert_select "input[type=date][name='quote[departure_end_on]']"
    start = Date.current + 180
    post quotes_path, params: { client_id: @client.id, quote: {
      perfectbook_trip_id: trip.perfectbook_id, party_size: 1, valid_until: Date.current + 14,
      departure_start_on: start, departure_end_on: start + 10,
      lines_attributes: { "0" => { kind: "trip", description: "Private trek", quantity: 1, unit_dollars: "3975" } }
    } }
    quote = Quote.ordered.first
    assert_redirected_to quote_path(quote)
    assert_equal start, quote.departure_start_on
    assert_equal start, quote.lines.first.snapshot_start_on
    get edit_quote_path(quote)
    assert_select "input[type=date][name='quote[departure_start_on]']"
    patch quote_path(quote), params: { quote: { departure_start_on: start + 1, departure_end_on: start + 11 } }
    assert_equal start + 1, quote.reload.departure_start_on
    assert_equal start + 1, quote.lines.first.snapshot_start_on
    complete_quote_terms(quote, journey_kind: "private")
    assert quote.deliver!
  end

  test "delivered terms follow conversion and recipient identity without leaking to other people" do
    lead = Lead.create!(name: "Lead Traveler", email: "lead@example.com")
    quote = Quote.create!(lead: lead, party_size: 1, valid_until: Date.current + 14)
    quote.lines.create!(description: "Journey", quantity: 1, unit_minor: 397_500)
    complete_quote_terms(quote, days: 180)
    assert quote.deliver!
    client = lead.convert_to_client!
    assert_equal QuoteTerms::VERSION, TemplateContext.for(client)["terms_version"]
    assert_includes Ai::Context.client_facts(client), quote.reference
    client.people.create!(name: "Traveler", email: "lead@example.com")
    assert_equal QuoteTerms::VERSION, TemplateContext.for_reply(to: "lead@example.com", owner: client)[:context]["terms_version"]
    PerfectBook::Contact.create!(perfectbook_id: 987, name: "Traveler", email: "lead@example.com", synced_at: Time.current)
    assert_equal QuoteTerms::VERSION, TemplateContext.for_reply(to: "lead@example.com", owner: client)[:context]["terms_version"]
    client.people.create!(name: "Other", email: "other@example.com")
    assert_nil TemplateContext.for_reply(to: "other@example.com", owner: client)[:context]["terms_version"]
  end
end
