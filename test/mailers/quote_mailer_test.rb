require "test_helper"

class QuoteMailerTest < ActionMailer::TestCase
  setup do
    @client = Client.create!(name: "Maya Gurung", email: "maya@example.com")
    @quote = Quote.create!(client: @client, trip_name: "Everest trek",
      party_size: 2, valid_until: Date.current + 14)
    @quote.lines.create!(kind: "trip", description: "Everest trek", quantity: 2, unit_dollars: "1500.00")
  end

  test "quote email comes from info@ with PDF and accept link" do
    mail = QuoteMailer.quote_email(@quote)
    assert_equal [ "maya@example.com" ], mail.to
    assert_equal "Sherpa Holidays <info@sherpaholidays.com>", mail[:from].value
    assert_includes mail.subject, @quote.reference
    assert_equal 1, mail.attachments.size
    assert_match(/quote-#{@quote.reference}\.pdf/, mail.attachments.first.filename)
    body = mail.text_part.decoded
    assert_includes body, "/q/#{@quote.accept_token}"
    assert_includes body, "$3,000.00"
  end

  test "accepted notice goes to the captain" do
    mail = QuoteMailer.accepted_notice(@quote)
    assert_equal [ "info@sherpaholidays.com" ], mail.to
    assert_includes mail.subject, @quote.reference
  end
end

class QuotePdfTest < ActiveSupport::TestCase
  test "renders a readable PDF with totals and the accept link" do
    client = Client.create!(name: "Maya Gurung", email: "maya@example.com")
    quote = Quote.create!(client: client, trip_name: "Everest trek",
      party_size: 2, valid_until: Date.current + 14,
      included: "Guides, lodges, permits.", notes: "Held two seats for you.")
    quote.lines.create!(kind: "trip", description: "Everest trek", quantity: 2, unit_dollars: "1500.00")
    bytes = QuotePdf.new(quote, accept_url: "https://perfectcrm.example.test/q/abc").render
    assert_match(/%PDF/, bytes)
    assert_operator bytes.bytesize, :>, 2_000
  end
end
