require "application_system_test_case"
require_relative "../support/google_sign_in_test_helper"

class InquiryCostsSystemTest < ApplicationSystemTestCase
  include GoogleSignInTestHelper

  def browser_sign_in
    OmniAuth.config.mock_auth[:google_oauth2] = OmniAuth::AuthHash.new(
      provider: "google_oauth2", extra: { id_token: JWT.encode(@claims, @key, "RS256") })
    Google::Auth::IDTokens.stub(:oidc_key_source, @source) { visit "/auth/google_oauth2/callback" }
    assert_text "Today"
  end

  def evidence(name)
    return unless ENV["INQUIRY_EVIDENCE_DIR"]
    image = page.driver.browser.execute_cdp("Page.captureScreenshot", captureBeyondViewport: true, fromSurface: true)
    File.binwrite(File.join(ENV.fetch("INQUIRY_EVIDENCE_DIR"), "#{name}.png"), Base64.decode64(image.fetch("data")))
    File.write(File.join(ENV.fetch("INQUIRY_EVIDENCE_DIR"), "#{name}.html"), page.html)
  end

  test "owner reads exact costs without personal data and unresolved ads survive a week" do
    page.driver.browser.manage.window.resize_to(1400, 900)
    visit inquiry_costs_path
    assert_current_path sign_in_path
    day = Date.yesterday
    AdSpend::SOURCES.each do |source|
      2.times do
        Lead.create!(name: "Private synthetic person", email: "private@example.test", message: "Private message",
          source: source, capture_channel: "website_form", received_at: day.in_time_zone + 10.hours,
          metadata: { "attribution" => { "campaign_id" => "123", "ad_id" => "456" } })
      end
      spam = Lead.create!(name: "Synthetic spam", source: source, capture_channel: "website_form",
        received_at: day.in_time_zone + 10.hours, metadata: { "attribution" => { "campaign_id" => "123", "ad_id" => "456" } })
      spam.tags << Tag.find_or_create_by!(name: Lead::SUSPECTED_SPAM_TAG)
      DailyAdSpend.record!(spent_on: day, source: source, campaign_id: "123", campaign_name: "Nepal",
        currency: "USD", amount_minor: 3000)
      DailyAdSpend.record!(spent_on: day, source: source, campaign_id: "123", campaign_name: "Nepal",
        currency: "USD", amount_minor: 2000, ad_id: "456", ad_name: "Mountain ad")
    end
    browser_sign_in
    visit channels_path
    click_link "Cost per inquiry"
    find("#start_date").set(day)
    find("#end_date").set(day)
    click_button "View report"
    assert_current_path inquiry_costs_path, ignore_query: true
    assert_selector "#start_date[value='#{day.iso8601}']"
    within("section[aria-label='By day']") { assert_text "$30.00 USD"; assert_text "$15.00 USD" }
    within("section[aria-label='Ads by day']") { assert_text "$20.00 USD"; assert_text "$10.00 USD" }
    assert_no_text "Private synthetic person"
    assert_no_text "private@example.test"
    assert_no_text "Private message"
    assert_selector ".inquiry-cost-facts", text: /Genuine inquiries\s*4\s*Suspected spam excluded\s*2/
    evidence("exact-costs-desktop")
    page.driver.browser.manage.window.resize_to(390, 844)
    evidence("exact-costs-phone")
    assert page.evaluate_script("document.documentElement.scrollWidth <= window.innerWidth"), "Page overflows phone viewport"
    page.driver.browser.manage.window.resize_to(1400, 900)
    [false, true].each do |ambiguous|
      DailyAdSpend.delete_all
      Lead.delete_all
      AdSpend::SOURCES.each do |source|
        if ambiguous
          %w[123 999].each do |id|
            DailyAdSpend.record!(spent_on: day, source: source, campaign_id: id, campaign_name: "Shared name", currency: "USD", amount_minor: 1000)
          end
        end
        Lead.create!(name: "Synthetic unresolved", source: source, capture_channel: "website_form",
          received_at: day.in_time_zone + 10.hours, campaign_name: ambiguous ? "Shared name" : nil,
          metadata: { "attribution" => { "ad_id" => "456" } })
      end
      visit inquiry_costs_path
      assert_selector "section[aria-label='Ads by day'] tbody tr", count: 14
      page.all("section[aria-label='Ads by day'] tbody tr").each do |row|
        cells = row.all("td").map(&:text)
        assert_equal "Unknown", cells[2]
        assert_equal "Ad 456", cells[3]
        assert_equal "Unknown", cells[4]
        assert_equal "Unknown", cells[6]
      end
      evidence(ambiguous ? "ambiguous-campaign-week" : "missing-campaign-week")
    end
    visit inquiry_costs_path(start_date: (day - 31).iso8601, end_date: day.iso8601)
    assert_selector "[role=alert]", text: "Choose up to 31 complete days within the last two years."
    evidence("invalid-range")
  end
  test "daily spend publisher replaces ad identities and rejects unauthorized or invalid batches" do
    require "net/http"
    old_token = ENV["CHANNEL_CHECKS_TOKEN"]
    ENV["CHANNEL_CHECKS_TOKEN"] = "synthetic-browser-token"
    visit sign_in_path
    uri = URI("#{Capybara.current_session.server.base_url}/api/v1/channels/daily_spend")
    row = { spent_on: Date.yesterday.iso8601, source: "google_ads", campaign_id: "live-123",
      campaign_name: "Live Nepal", currency: "USD", amount_minor: 3000 }
    transcript = []
    send_rows = lambda do |rows, token|
      request = Net::HTTP::Post.new(uri)
      request["Content-Type"] = "application/json"
      request["Authorization"] = "Bearer #{token}"
      request.body = { spends: rows }.to_json
      response = Net::HTTP.start(uri.hostname, uri.port) { |http| http.request(request) }
      transcript << "HTTP #{response.code}: #{response.body}"
      response
    end
    assert_equal "401", send_rows.call([row], "wrong").code
    assert_equal "201", send_rows.call([row, row.merge(ad_id: "live-456", amount_minor: 2000)], ENV["CHANNEL_CHECKS_TOKEN"]).code
    assert_equal "201", send_rows.call([row.merge(ad_id: "live-456", amount_minor: 1500)], ENV["CHANNEL_CHECKS_TOKEN"]).code
    assert_equal 1500, DailyAdSpend.find_by!(ad_id: "live-456").amount_minor
    assert_equal "422", send_rows.call([row.merge(amount_minor: 9000), row.merge(ad_id: "bad", amount_minor: -1)], ENV["CHANNEL_CHECKS_TOKEN"]).code
    assert_equal 3000, DailyAdSpend.find_by!(campaign_id: "live-123", ad_id: "").amount_minor
    if ENV["INQUIRY_EVIDENCE_DIR"]
      File.write(File.join(ENV.fetch("INQUIRY_EVIDENCE_DIR"), "spend-api.txt"), transcript.join("\n"))
    end
  ensure
    ENV["CHANNEL_CHECKS_TOKEN"] = old_token
  end

end
