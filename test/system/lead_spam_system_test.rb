require "application_system_test_case"
require_relative "../support/google_sign_in_test_helper"

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
      assert_selector "h2", text: "Archived"
      within("li", text: lead.name) do
        assert_text "Spam"
        assert_button "Not spam"
      end
      assert lead.reload.archived?
      assert lead.spam_marked_at
      assert_operator page.evaluate_script("document.documentElement.scrollWidth"), :<=, width
      find("li", text: lead.name).scroll_to(:center)
      page.save_screenshot("/home/sam/.no-mistakes/evidence/01M504CM9P5RVT101WFY2SDT55/archive-#{width}.png")
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
      assert_selector "h1", text: lead.name
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
    page.save_screenshot("/home/sam/.no-mistakes/evidence/01M504CM9P5RVT101WFY2SDT55/suspected-spam.png")
    within("section[aria-label='Spam review']") { click_button "Not spam" }
    assert_text "Marked as not spam"
    assert_no_selector "section[aria-label='Spam review']"
    assert_equal 75, lead.reload.spam_score
    assert_not lead.suspected_spam?
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
end
