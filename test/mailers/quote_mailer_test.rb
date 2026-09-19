require "test_helper"

class QuoteMailerTest < ActionMailer::TestCase
  LOGO_BYTES = Base64.decode64(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
  ).freeze

  setup do
    @client = Client.create!(name: "Maya Gurung", email: "maya@example.com")
    @quote = Quote.create!(client: @client, trip_name: "Everest trek",
      party_size: 2, valid_until: Date.current + 14)
    @quote.lines.create!(kind: "trip", description: "Everest trek", quantity: 2, unit_dollars: "1500.00")
    Setting.current.update!(email_signature: "Sam Sherpa", email_signature_html: "")
  end

  teardown do
    setting = Setting.current
    setting.signature_logo.purge if setting.signature_logo.attached?
    setting.update!(email_signature: "", email_signature_html: "")
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

  test "Unicode names notes and line descriptions deliver with a PDF" do
    @client.update!(name: "माया गुरुङ")
    @quote.update!(notes: "नमस्ते 🏔️ 🥾", included: "अनुमति र गाइड")
    @quote.lines.first.update!(description: "हिमालय यात्रा 🏔️")
    assert_emails 1 do
      mail = QuoteMailer.quote_email(@quote).deliver_now
      assert_includes mail.text_part.decoded, "नमस्ते"
      assert_match(/%PDF/, mail.attachments.first.decoded)
    end
  end

  test "accepted notice goes to the captain" do
    mail = QuoteMailer.accepted_notice(@quote)
    assert_equal [ "info@sherpaholidays.com" ], mail.to
    assert_includes mail.subject, @quote.reference
  end

  test "quote email carries the text signature in the text part" do
    mail = QuoteMailer.quote_email(@quote)
    assert_includes mail.text_part.decoded, "Sam Sherpa"
  end

  test "quote email carries the HTML signature with the embedded logo" do
    Setting.current.signature_logo.attach(
      io: StringIO.new(LOGO_BYTES), filename: "logo.png", content_type: "image/png"
    )
    mail = QuoteMailer.quote_email(@quote)
    html = mail.html_part.body.to_s
    assert_includes html, "Sam Sherpa"
    assert_includes html, "cid:#{EmailSignature::CID}"
    inline = mail.attachments.find { |attachment| attachment.filename == "signature-logo.png" }
    assert inline.inline?
    assert_equal "<#{EmailSignature::CID}>", inline.content_id
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
