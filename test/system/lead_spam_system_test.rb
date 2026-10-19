require "application_system_test_case"
require_relative "../support/google_sign_in_test_helper"
require "net/http"

class LeadSpamSystemTest < ApplicationSystemTestCase
  include GoogleSignInTestHelper

  setup do
    OmniAuth.config.mock_auth[:google_oauth2] = OmniAuth::AuthHash.new(
      provider: "google_oauth2", uid: "google-captain",
      extra: { id_token: JWT.encode(@claims, @key, "RS256") })
    Google::Auth::IDTokens.stub(:oidc_key_source, @source) do
      visit "/auth/google_oauth2/callback"
      assert_selector "h1", text: "Today"
    end
  end

  test "owner archives spam from list and record and restores intact at desktop and phone widths" do
    [ 1400, 390 ].each do |width|
      page.current_window.resize_to(width, 900)
      lead = Lead.create!(name: "Spam review #{width}", message: "Original inquiry", tag_list: "trekking")
      lead.notes.create!(body: "Preserved history")
      thread = Conversation.create!(linkable: lead, subject: "Unanswered #{width}")
      thread.messages.create!(direction: "in", sent_at: 1.hour.ago, text_body: "Original inquiry")
      replied = Conversation.create!(linkable: lead, subject: "Replied #{width}")
      replied.messages.create!(direction: "out", status: "sent", sent_at: Time.current, to_addrs: "traveler@example.test", subject: replied.subject, text_body: "Reply")
      Task.create!(subject: lead, title: "Review spam #{width}", due_on: Date.current)
      visit inbox_path(tab: "waiting")
      assert_link thread.subject
      visit leads_path
      if width == 1400
        within("li", text: lead.name) { click_button "Mark as spam" }
      else
        visit lead_path(lead)
        click_button "Mark as spam"
      end
      assert_selector "h2", text: "New"
      assert_no_text lead.name
      assert lead.reload.archived?
      assert lead.spam_marked_at
      assert_operator page.evaluate_script("document.documentElement.scrollWidth"), :<=, width
      visit leads_path(tab: "archived")
      within("li", text: lead.name) do
        assert_text "Spam"
        assert_button "Not spam"
      end
      visit leads_path
      assert_no_link lead.name
      %w[waiting waiting_them all].each do |tab|
        visit inbox_path(tab: tab)
        assert_no_link thread.subject
        assert_no_link replied.subject
        %w[waiting waiting_them all].each do |key|
          assert_selector "nav.tabs a[href='#{inbox_path(tab: key)}']", text: /0/
        end
      end
      visit root_path
      assert_no_text "Review spam #{width}"
      visit leads_path(tab: "archived")
      within("li", text: lead.name) { click_button "Not spam" }
      assert_selector "h2", text: "Archived"
      assert_no_text lead.name
      assert_not lead.reload.archived?
      assert_not lead.suspected_spam?
      assert_equal "Original inquiry", lead.message
      assert_equal [ "trekking" ], lead.tags.pluck(:name)
      assert_equal "Preserved history", lead.notes.last.body
      visit inbox_path(tab: "waiting")
      assert_link thread.subject
      visit inbox_path(tab: "waiting_them")
      assert_link replied.subject
      # Remove this iteration's records from queues before checking zero counts.
      visit lead_path(lead)
      click_button "Mark as spam"
    end
  end

  test "automatic suspicion can be rejected and converted records cannot be marked" do
    page.current_window.resize_to(1400, 900)
    lead = Lead.create!(name: "False positive", spam_score: 75, tag_list: "suspected_spam, trekking")
    visit lead_path(lead)
    assert_text "Looks like spam"
    within("section[aria-label='Spam review']") { click_button "Not spam" }
    assert_text "Not spam - restored to New."
    assert_no_selector "section[aria-label='Spam review']"
    assert_equal 75, lead.reload.spam_score
    assert_not lead.suspected_spam?
    visit lead_path(lead)
    accept_confirm { click_button "Convert to client" }
    assert_text "Started as a lead"
    visit lead_path(lead)
    assert_no_button "Mark as spam"
    assert_no_button "Not spam"
    # Forge the mutation through the browser to exercise the server guard.
    page.execute_script(<<~JS)
      const form = document.createElement('form'); form.method = 'post';
      form.action = '#{mark_as_spam_lead_path(lead)}';
      const input = document.createElement('input'); input.name = '_method'; input.value = 'patch';
      form.appendChild(input); document.body.appendChild(form); form.submit();
    JS
    assert_text "Converted leads stay read-only"
    assert_nil lead.reload.spam_marked_at
    assert_not lead.archived?
  end

  test "fast bot intake lands in Archived with reason and duplicate intake merges onto timeline" do
    page.current_window.resize_to(1400, 900)
    settings = Setting.current
    settings.update!(lead_webhook_url: nil)
    settings.rotate_site_key!
    seq = 0
    post_intake = lambda do |payload|
      seq += 1
      uri = URI("#{Capybara.current_session.server.base_url}/api/v1/leads/intake")
      req = Net::HTTP::Post.new(uri)
      req["X-Forwarded-For"] = "198.51.100.#{seq}"
      req["Content-Type"] = "application/json"
      req["Origin"] = "https://www.sherpaholidays.com"
      req["X-Sherpa-Site-Key"] = settings.site_key
      req.body = JSON.generate(payload)
      Net::HTTP.start(uri.host, uri.port) { |http| http.request(req) }
    end

    post_intake.call(
      schema: "sherpa.inquiry.v2", submission_id: "550e8400-e29b-41d4-a716-446655440991", placement: "landing",
      contact: { name: "Speedy Bot", email: "speedy@example.com" }, message: "Fast bot inquiry",
      consent: { contact: true, contact_at: "2026-04-17T18:02:11Z", text_version: "v2" },
      timing: { started_at: "2026-04-17T18:02:10Z", submitted_at: "2026-04-17T18:02:11Z" }, honeypot: ""
    )
    post_intake.call(
      schema: "sherpa.inquiry.v2", submission_id: "550e8400-e29b-41d4-a716-446655440992", placement: "landing",
      contact: { name: "Maya Sherpa", email: "maya@example.com" }, message: "Planning an October trek for two.",
      consent: { contact: true, contact_at: "2026-04-17T18:02:25Z", text_version: "v2" },
      timing: { started_at: "2026-04-17T18:02:00Z", submitted_at: "2026-04-17T18:02:25Z" }, honeypot: ""
    )
    post_intake.call(
      schema: "sherpa.inquiry.v2", submission_id: "550e8400-e29b-41d4-a716-446655440993", placement: "landing",
      contact: { name: "Maya Sherpa", email: "maya@example.com" }, message: "Planning an October trek for two!",
      consent: { contact: true, contact_at: "2026-04-17T18:05:25Z", text_version: "v2" },
      timing: { started_at: "2026-04-17T18:05:00Z", submitted_at: "2026-04-17T18:05:25Z" }, honeypot: ""
    )

    visit leads_path
    assert_link "Maya Sherpa", count: 1
    assert_no_link "Speedy Bot"

    visit leads_path(tab: "archived")
    within("li", text: "Speedy Bot") do
      assert_text "Spam"
      assert_text "Submitted under 3s"
    end

    click_link "Speedy Bot"
    within("section[aria-label='Spam review']") do
      assert_text "Marked as spam"
      assert_text "Submitted under 3s"
    end

    visit leads_path
    click_link "Maya Sherpa"
    assert_text "Duplicate website inquiry merged: Planning an October trek for two!"
  end
end
