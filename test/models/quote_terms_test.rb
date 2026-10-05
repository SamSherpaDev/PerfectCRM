require "test_helper"
require_relative "../support/quote_terms_test_helper"

class QuoteTermsTest < ActiveSupport::TestCase
  include QuoteTermsTestHelper

  setup do
    @client = Client.create!(name: "Synthetic Traveler", email: "traveler@example.com")
    @quote = Quote.create!(client: @client, party_size: 1, valid_until: Date.current + 14)
    @quote.lines.create!(description: "Synthetic trip", quantity: 1, unit_minor: 397_500)
  end

  test "payment schedule covers scheduled private and exact 90 day boundary" do
    %w[scheduled private].each do |kind|
      [ 91, 90, 89 ].each do |days|
        @quote.assign_attributes(journey_kind: kind, departure_start_on: Date.current + days)
        expected = days <= 90 ? 397_500 : (kind == "scheduled" ? 50_000 : 119_250)
        assert_equal expected, QuoteTerms.deposit_minor(@quote)
      end
    end
  end

  test "incomplete disclosure cannot send and drafts remain valid" do
    assert @quote.valid?
    assert_not @quote.deliver!
    assert_includes @quote.errors.full_messages.join, "Complete"
    assert_nil @quote.reload.terms_bundle
    complete_quote_terms(@quote)
    @quote.disclosure_details["security_evidence"] = "unknown"
    @quote.save!
    assert_not @quote.deliver!
  end

  test "delivery snapshots exact master disclosure one branch and accepted evidence" do
    complete_quote_terms(@quote, days: 91)
    assert @quote.deliver!, @quote.errors.full_messages.join
    bundle = @quote.reload.terms_bundle
    assert_equal QuoteTerms.source("master-terms").sub("[verified operator legal name]", "Synthetic Operator LLC"), bundle["master_terms"]
    assert_includes bundle["pre_payment_disclosure"], "This transaction is covered"
    assert_not_includes bundle["pre_payment_disclosure"], "This transaction is not covered"
    assert_not_includes bundle["pre_payment_disclosure"], "____________________"
    assert_equal Digest::SHA256.hexdigest(JSON.generate(bundle)), @quote.terms_bundle_sha256
    assert_not @quote.accept!
    assert_not @quote.accept!(bundle_sha256: "stale")
    assert @quote.accept!(bundle_sha256: @quote.terms_bundle_sha256)
    details = @quote.reload.intake_details
    assert_equal QuoteTerms::VERSION, details["accepted_terms_version"]
    assert_equal bundle, details["terms_bundle"]
    assert_equal 50_000, details["deposit_minor"]
    assert_equal @quote.accepted_at.iso8601, details["accepted_at"]
    assert_includes @quote.perfectbook_intake_url, "terms_version=SH-TC-2026-10-04"
    assert_not @quote.update(accepted_bundle_sha256: "changed")
  end

  test "delivered quote lines documents identity and payment are immutable" do
    complete_quote_terms(@quote)
    assert @quote.deliver!
    @client.update!(name: "Changed name")
    assert_equal "Synthetic Traveler", @quote.owner_name
    assert_not @quote.update(notes: "New rights removed")
    @quote.reload
    assert_not @quote.lines.first.update(unit_minor: 1)
    assert_not @quote.lines.first.destroy
    copy = @quote.duplicate!
    assert_nil copy.terms_bundle
    assert_nil copy.accepted_terms_version
    assert_equal @quote.total_minor, copy.total_minor
    revision = @quote.new_revision!
    assert_nil revision.terms_bundle
    assert_equal @quote.terms_bundle, @quote.reload.terms_bundle
  end

  test "crossing the 90 day booking boundary needs a new quote without rewriting delivery" do
    complete_quote_terms(@quote, days: 91)
    assert @quote.deliver!
    bundle = @quote.terms_bundle
    travel 1.day do
      assert_not @quote.acceptable?
      assert_not @quote.accept!(bundle_sha256: @quote.terms_bundle_sha256)
      assert_equal bundle, @quote.reload.terms_bundle
    end
  end

  test "not covered notice excludes covered notice" do
    complete_quote_terms(@quote)
    @quote.disclosure_details["fund_notice"] = "not_covered"
    @quote.save!
    assert @quote.deliver!
    assert_includes @quote.terms_bundle["pre_payment_disclosure"], "This transaction is not covered"
    assert_not_includes @quote.terms_bundle["pre_payment_disclosure"], "This transaction is covered"
  end

  test "reported prior payments reduce the requested amount and never count twice" do
    complete_quote_terms(@quote, days: 180)
    @quote.disclosure_details["paid_to_date"] = "400.00"
    @quote.save!
    assert @quote.deliver!
    assert_equal 10_000, @quote.payment_requested_minor
    assert_equal 347_500, @quote.remaining_balance_minor
    assert_includes @quote.terms_bundle["pre_payment_disclosure"], "| Amount paid to date | $400.00 |"
    assert_includes @quote.terms_bundle["pre_payment_disclosure"], "| Payment requested now: amount and purpose | $100.00:"
    assert_equal "$100.00", TemplateContext.for(@client)["deposit_due"]
    assert @quote.accept!(bundle_sha256: @quote.terms_bundle_sha256)
    assert_equal 40_000, @quote.intake_details["paid_to_date_minor"]
    assert_equal 10_000, @quote.intake_details["payment_now_minor"]
  end

  test "prior payment field must be exact dollars within the quote total" do
    complete_quote_terms(@quote)
    [ "1,000", "already paid", "3975.01" ].each do |amount|
      @quote.disclosure_details["paid_to_date"] = amount
      @quote.save!
      assert_not @quote.deliver!
      assert_includes @quote.errors.full_messages.join, "Amount paid to date must be US dollars"
    end
  end

  test "old sent quote is not backfilled with new terms" do
    @quote.update!(status: "sent", sent_at: Time.current)
    assert @quote.accept!
    assert_nil @quote.reload.terms_bundle
    assert_nil @quote.accepted_terms_version
  end
end
