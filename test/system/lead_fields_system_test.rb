require "application_system_test_case"
require_relative "../support/google_sign_in_test_helper"
require "net/http"
require "rake"

class LeadFieldsSystemTest < ApplicationSystemTestCase
  include GoogleSignInTestHelper
  EVIDENCE = ENV.fetch("LEAD_FIELDS_EVIDENCE", Rails.root.join("tmp/lead-fields-evidence").to_s)

  test "website intake details conversion and raw phone are visible" do
    login_captain
    settings = Setting.current
    settings.update!(lead_webhook_url: nil)
    settings.rotate_site_key!
    formats = { "4155550134" => "+14155550134", "14155550134" => "+14155550134", "(415) 555-0134" => "+14155550134", "415 555 0134" => "+14155550134", "415.555.0134" => "+14155550134", "415-555-0134" => "+14155550134", "+44 20 7946 0958" => "+442079460958", "call reception" => nil, "4155550134 ext 2" => nil, "+0000000000" => nil, "" => nil }
    transcript = []
    formats.each_with_index do |(raw, expected), index|
      id = SecureRandom.uuid
      body = { schema: "sherpa.inquiry.v2", submission_id: id, placement: "landing",
        contact: { name: "Website Visitor #{index}", email: "visitor#{index}@example.com", phone_raw: raw },
        trip: { handle: "nepal", title: "Nepal journey" }, message: "A spring trip please",
        consent: { contact: true, contact_at: Time.current.iso8601, text_version: "v2" },
        page: { template: "page.contact", locale: "en-US" }, honeypot: "" }
      response = api_post("/api/v1/leads/intake", body, settings.site_key)
      assert_equal "202", response.code, response.body
      lead = Lead.find(JSON.parse(response.body).fetch("id"))
      expected.nil? ? assert_nil(lead.phone) : assert_equal(expected, lead.phone)
      assert_nil lead.country
      assert_nil lead.party_size
      assert_nil lead.travel_month
      assert_equal "page.contact", lead.metadata.dig("page", "template")
      if index == 0
        details = api_post("/api/v1/leads/intake/details", { schema: "sherpa.inquiry.details.v1", submission_id: id,
          trip: { month: 4, year: 2027, timing_unknown: false, budget_band: "4000_7000" }, party: { size: 3 } }, settings.site_key)
        assert_equal "200", details.code, details.body
        source = api_post("/api/v1/leads/intake/details", { schema: "sherpa.inquiry.details.v1", submission_id: id,
          source_answer: { code: "personal_referral", detail: "Synthetic friend", question_version: "how-heard-v1" } }, settings.site_key)
        assert_equal "200", source.code, source.body
        lead.reload
        assert_equal [ 4, 2027, 3, "4000_7000", "Synthetic friend" ], [ lead.travel_month, lead.travel_year, lead.party_size, lead.budget_band, lead.reported_source_detail ]
      end
      visit lead_path(lead)
      assert_text(expected || raw) unless raw.empty?
      find("dd", text: expected || raw, exact_text: true).execute_script("this.scrollIntoView({block: 'center'})") unless raw.empty?
      if index.in?([ 0, 7 ])
        page.save_screenshot(File.join(EVIDENCE, "lead-#{index}.png"))
      end
      accept_confirm { click_button "Convert to client" }
      assert_text "Started as a lead"
      client = lead.reload.converted_client
      expected.nil? ? assert_nil(client.phone) : assert_equal(expected, client.phone)
      raw.empty? ? assert_nil(client.phone_raw) : assert_equal(raw, client.phone_raw)
      assert_text(expected || raw) unless raw.empty?
      find("dd", text: expected || raw, exact_text: true).execute_script("this.scrollIntoView({block: 'center'})") unless raw.empty?
      page.save_screenshot(File.join(EVIDENCE, "client-#{index}.png")) if index.in?([ 0, 7 ])
      transcript << { raw: raw, response: JSON.parse(response.body), phone: client.phone, raw_retained: client.phone_raw, country: client.country }
    end
    foreign = api_post("/api/v1/leads/intake", { schema: "sherpa.inquiry.v2", submission_id: SecureRandom.uuid, placement: "landing",
      contact: { name: "UK visitor", email: "uk@example.com", phone_raw: "020 7946 0958", country: "GB" }, message: "Hello",
      consent: { contact: true, contact_at: Time.current.iso8601, text_version: "v2" }, honeypot: "" }, settings.site_key)
    assert_equal "202", foreign.code
    lead = Lead.find(JSON.parse(foreign.body).fetch("id"))
    assert_nil lead.phone
    assert_equal "GB", lead.country
    visit lead_path(lead)
    assert_text "020 7946 0958"
    page.current_window.resize_to(390, 844)
    visit lead_path(lead)
    click_button "Details", exact: true
    assert_operator page.evaluate_script("document.documentElement.scrollWidth"), :<=, 390
    find("dd", text: "020 7946 0958").execute_script("this.scrollIntoView({block: 'center'})")
    page.save_screenshot(File.join(EVIDENCE, "foreign-phone-mobile.png"))
    File.write(File.join(EVIDENCE, "intake-results.json"), JSON.pretty_generate(transcript))
  end

  test "recovery task repairs searches without overwriting or spreading phones" do
    login_captain
    lead = Lead.create!(name: "Recovered Booker", email: "recovered@example.com", phone_raw: "4155550134")
    lead.people.create!(name: "Booker", email: lead.email)
    lead.people.create!(name: "Companion", email: "companion@example.com")
    client = lead.convert_to_client!
    client.update_columns(phone_raw: nil)
    other = Client.create!(name: "Unrelated client")
    unrelated = other.people.create!(name: "Same email", email: lead.email)
    existing = Lead.create!(name: "Existing phone", phone: "+14155550199", phone_raw: "4155550134")
    invalid = Lead.create!(name: "Reception", phone_raw: "call reception")
    owners = [ lead, client ]
    timestamps = owners.map { |o| o.reload.attributes.slice("updated_at", "last_activity_at") }
    Rails.application.load_tasks unless Rake::Task.task_defined?("leads:backfill_phones")
    first, = capture_io { Rake::Task["leads:backfill_phones"].execute }
    assert_equal 1, JSON.parse(first)["leads_updated"]
    assert_equal timestamps, owners.map { |o| o.reload.attributes.slice("updated_at", "last_activity_at") }
    assert_nil unrelated.reload.phone
    assert_nil client.people.find_by!(email: "companion@example.com").phone
    assert_equal "+14155550199", existing.reload.phone
    assert_nil invalid.reload.phone
    assert_equal "+14155550134", client.people.find_by!(email: lead.email).phone
    visit leads_path(q: "5550134", tab: "converted")
    assert_text "Recovered Booker"
    visit clients_path(q: "5550134")
    assert_text "Recovered Booker"
    page.save_screenshot(File.join(EVIDENCE, "recovered-client-search.png"))
    second, = capture_io { Rake::Task["leads:backfill_phones"].execute }
    assert_equal 0, JSON.parse(second)["leads_updated"]
    assert_equal 0, JSON.parse(second)["clients_updated"]
    assert_equal 0, JSON.parse(second)["people_updated"]
    returning = Lead.create!(name: "Returning", email: "returning@example.com", phone: "+14155550134", phone_raw: "415-555-0134")
    returning_client = Client.create!(name: "Returning", email: returning.email)
    visit lead_path(returning)
    accept_confirm { click_button "Convert to client" }
    assert_current_path client_path(returning_client)
    assert_equal "+14155550134", returning_client.reload.phone
    subsequent = Lead.create!(name: "Returning again", email: returning.email, phone: "+14155550199")
    visit lead_path(subsequent)
    accept_confirm { click_button "Convert to client" }
    assert_current_path client_path(returning_client)
    assert_equal "+14155550134", returning_client.reload.phone
    File.write(File.join(EVIDENCE, "recovery-results.json"), JSON.pretty_generate({ first: JSON.parse(first), second: JSON.parse(second), timestamps_preserved: true, unrelated_phone: unrelated.phone, existing_phone: existing.phone, returning_phone: returning_client.phone }))
  end

  private
  def login_captain
    FileUtils.mkdir_p(EVIDENCE)
    OmniAuth.config.mock_auth[:google_oauth2] = OmniAuth::AuthHash.new(provider: "google_oauth2", uid: "google-captain", extra: { id_token: JWT.encode(@claims, @key, "RS256") })
    Google::Auth::IDTokens.stub(:oidc_key_source, @source) { visit "/auth/google_oauth2/callback"; assert_selector "h1", text: "Today" }
    page.current_window.resize_to(1400, 900)
  end
  def api_post(path, body, key)
    uri = URI("#{Capybara.current_session.server.base_url}#{path}")
    request = Net::HTTP::Post.new(uri)
    @request_number = (@request_number || 0) + 1
    request["X-Forwarded-For"] = "192.0.2.#{@request_number}"
    request["Content-Type"] = "application/json"
    request["Origin"] = "https://www.sherpaholidays.com"
    request["X-Sherpa-Site-Key"] = key
    request.body = JSON.generate(body)
    Net::HTTP.start(uri.host, uri.port) { |http| http.request(request) }
  end
end
