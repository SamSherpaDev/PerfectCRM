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

  test "documents download mail and PDF contain the same immutable texts" do
    get public_quote_documents_path(@quote.accept_token)
    assert_response :success
    assert_equal @quote.terms_bundle, response.parsed_body
    email = QuoteMailer.quote_email(@quote)
    %w[master_terms pre_payment_disclosure trip_differences itinerary].each do |name|
      assert_equal @quote.terms_bundle.fetch(name), email.attachments["#{@quote.reference}-#{name}.txt"].decoded
    end
    pdf_text = PDF::Reader.new(StringIO.new(email.attachments["quote-#{@quote.reference}.pdf"].decoded)).pages.map(&:text).join
    assert_includes pdf_text, QuoteTerms::VERSION
    assert_includes pdf_text, "45 days or fewer"
    assert_includes pdf_text, "Westfield National Insurance Company"
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
end
