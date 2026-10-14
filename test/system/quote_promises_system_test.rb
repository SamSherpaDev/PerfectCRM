require "application_system_test_case"
require "pdf/reader"
require_relative "../support/google_sign_in_test_helper"
require_relative "../support/quote_terms_test_helper"

class QuotePromisesSystemTest < ApplicationSystemTestCase
  include GoogleSignInTestHelper
  include QuoteTermsTestHelper

  test "captain previews promises and traveler receives frozen promises with historical boundary" do
    evidence = ENV.fetch("QUOTE_PROMISES_EVIDENCE", Rails.root.join("tmp/quote-promises-evidence").to_s)
    FileUtils.mkdir_p(evidence)
    client = Client.create!(name: "Synthetic Traveler", email: "traveler@example.com")
    quote = Quote.create!(client: client, party_size: 2, valid_until: Date.current + 14)
    quote.lines.create!(description: "Synthetic journey", quantity: 2, unit_minor: 397_500)
    complete_quote_terms(quote, days: 180)
    OmniAuth.config.mock_auth[:google_oauth2] = OmniAuth::AuthHash.new(provider: "google_oauth2", uid: "google-captain",
      extra: { id_token: JWT.encode(@claims, @key, "RS256") })
    Google::Auth::IDTokens.stub(:oidc_key_source, @source) do
      visit "/auth/google_oauth2/callback"
      assert_selector "h1", text: "Today"
    end
    page.current_window.resize_to(1400, 900)
    visit edit_quote_path(quote)
    find("summary", text: "Preview If things go wrong").click
    assert_selector "#if-things-go-wrong-heading", text: "If things go wrong"
    page.execute_script("document.querySelector('#if-things-go-wrong-heading').scrollIntoView({behavior: 'instant', block: 'start'})")
    page.save_screenshot(File.join(evidence, "builder-preview.png"))
    draft = PDF::Reader.new(StringIO.new(QuotePdf.new(quote, accept_url: "https://example.test/q/demo").render))
    assert_equal "If things go wrong", draft.pages.second.text.lines.map(&:strip).find { |line| line == "If things go wrong" }
    assert quote.deliver!
    email = QuoteMailer.quote_email(quote)
    bytes = email.attachments["quote-#{quote.reference}.pdf"].decoded
    File.binwrite(File.join(evidence, "delivered-quote.pdf"), bytes)
    pdf = PDF::Reader.new(StringIO.new(bytes))
    promises = pdf.pages.second.text.gsub(/\s+/, " ")
    assert_includes promises, "we cover up to 2 extra nights while you wait, and more when the situation calls for it."
    assert_includes promises, "Scheduled departures have no minimum group size."
    assert_includes promises, "within 60 days of departure"
    assert_includes promises, "at least 90 days before your trip starts"
    assert_includes promises, "They do not change your terms or refunds required by law."
    assert_no_match(/guarantee/i, promises)
    page.driver.browser.manage.delete_all_cookies
    QuoteTerms.stub(:if_things_go_wrong, "Future summary wording") do
      visit public_quote_path(quote.accept_token)
      within("section[aria-labelledby='if-things-go-wrong-heading']") do
        assert_selector "h3", count: 4
        assert_text "we cover up to 2 extra nights"
        assert_no_text "Future summary wording"
      end
      page.execute_script("document.querySelector('#if-things-go-wrong-heading').scrollIntoView({behavior: 'instant', block: 'start'})")
      page.save_screenshot(File.join(evidence, "public-desktop.png"))
      page.current_window.resize_to(390, 844)
      page.execute_script("document.querySelector('#if-things-go-wrong-heading').scrollIntoView({behavior: 'instant', block: 'start'})")
      assert page.evaluate_script("document.documentElement.scrollWidth <= window.innerWidth"), "Mobile overflow"
      page.save_screenshot(File.join(evidence, "public-phone.png"))
      require "net/http"
      uri = URI(page.current_url.sub(/\?.*/, "") + "/documents")
      response = Net::HTTP.get_response(uri)
      assert_equal "200", response.code
      assert_equal quote.terms_bundle, JSON.parse(response.body)
      File.binwrite(File.join(evidence, "delivered-documents.json"), response.body)
    end
    historical = Quote.create!(client: client, party_size: 2, valid_until: Date.current + 14)
    historical.lines.create!(description: "Historical synthetic journey", quantity: 1, unit_minor: 100_000)
    complete_quote_terms(historical, days: 180)
    bundle = QuoteTerms.bundle(historical).except("if_things_go_wrong")
    historical.update!(status: "sent", sent_at: Time.current, terms_bundle: bundle,
      terms_bundle_sha256: Digest::SHA256.hexdigest(JSON.generate(bundle)))
    visit public_quote_path(historical.accept_token)
    assert_no_selector "#if-things-go-wrong-heading"
    assert_equal bundle, historical.reload.terms_bundle
    pdf = PDF::Reader.new(StringIO.new(QuotePdf.new(historical, accept_url: page.current_url).render))
    assert_not_includes pdf.pages.map(&:text).join, "If things go wrong"
  end
end
