module QuoteTermsTestHelper
  # Synthetic only, including explicitly test-only security evidence.
  def complete_quote_terms(quote, journey_kind: "scheduled", days: 30)
    start = quote.departure_start_on || Date.current + days
    quote.update!(journey_kind: journey_kind, local_operator: "Synthetic Operator LLC",
      trip_name: quote.trip_name.presence || "Synthetic journey",
      departure_start_on: start, departure_end_on: quote.departure_end_on || start + 10,
      party_size: quote.party_size || 1, included: quote.included.presence || "Synthetic itinerary services",
      trip_differences: "None", balance_due_on: start - 90,
      disclosure_details: QuoteTerms::FIELDS.keys.index_with { |key| "Synthetic #{key} evidence" }.merge("fund_notice" => "covered"))
    quote.update!(deposit_minor: QuoteTerms.deposit_minor(quote))
    quote
  end
end
