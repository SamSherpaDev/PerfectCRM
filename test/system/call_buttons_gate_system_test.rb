require "application_system_test_case"
require_relative "../support/google_sign_in_test_helper"

class CallButtonsGateSystemTest < ApplicationSystemTestCase
  include GoogleSignInTestHelper

  setup do
    OmniAuth.config.mock_auth[:google_oauth2] = OmniAuth::AuthHash.new(
      provider: "google_oauth2", uid: "google-captain",
      extra: { id_token: JWT.encode(@claims, @key, "RS256") }
    )
    Google::Auth::IDTokens.stub(:oidc_key_source, @source) do
      visit "/auth/google_oauth2/callback"
      assert_selector "h1", text: "Today"
    end
    page.current_window.resize_to(1400, 900)
  end
  test "client buttons keep inquiries separate and replayed submission creates one call" do
    client = Client.create!(name: "Call Review", email: "call-review@example.com")
    first = Lead.create!(name: "First trip", reference: "SH-FIRST", existing_client: client)
    second = Lead.create!(name: "Second trip", reference: "SH-SECOND", existing_client: client)
    visit client_path(client)
    within("[aria-label='Calls for SH-FIRST']") do
      tolerate_submit_navigation { click_button "Talked" }
    end
    tolerate_navigation_assertion { assert_text "Call logged: Talked." }
    assert_equal 1, first.activity_events.where(kind: "call").count
    assert_equal 0, second.activity_events.where(kind: "call").count
    within("[aria-label='Calls for SH-SECOND']") do
      assert_text "No calls yet."
      # Replay the exact browser form, as a repeated click or network retry does.
      form = find("form")
      result = form.evaluate_async_script(<<~JS)
        const done = arguments[arguments.length - 1];
        const form = this;
        const body = new FormData(form);
        body.set('outcome', 'no_answer');
        Promise.all([1, 2].map(() => fetch(form.action, {method: 'POST', body})))
          .then(responses => done(responses.map(r => r.status)));
      JS
      assert_equal [ 200, 200 ], result
    end
    page.refresh
    within("[aria-label='Calls for SH-SECOND']") { assert_selector ".calls-recent li", count: 1, text: "No answer" }
    assert_equal 1, second.activity_events.where(kind: "call").count
    assert_equal 2, client.activity_events.where(kind: "call").count
    capture_calls("client-inquiries")
  end

  test "phone call buttons remain usable after logging" do
    lead = Lead.create!(name: "Phone review")
    page.current_window.resize_to(390, 844)
    visit lead_path(lead)
    find("button[data-tab='details']").click
    tolerate_submit_navigation { click_button "No answer" }
    tolerate_navigation_assertion { assert_text "Call logged: No answer." }
    assert_selector "button[data-tab='details'][aria-current='true']"
    within(".calls-recent") { assert_text "No answer" }
    capture_calls("phone-call-buttons")
  end

  test "tapping No answer and Voicemail for three unanswered attempts on an Unsure lead moves it to Not interested with a timeline note and supports manual undo" do
    lead = Lead.create!(name: "Don Campbell System", email: "three-vm-sys@example.com")
    lead.mark_unsure!
    CallLog.record!(lead, key: "sys-3vm-1", occurred_at: 3.days.ago, outcome: "voicemail", direction: "outbound")

    visit lead_path(lead, return_to: leads_path(tab: "unsure"))
    within(".calls") do
      tolerate_submit_navigation { click_button "No answer" }
    end
    tolerate_navigation_assertion { assert_text "Call logged: No answer." }
    assert lead.reload.unsure?

    within(".calls") do
      tolerate_submit_navigation { click_button "Voicemail" }
    end
    tolerate_navigation_assertion { assert_text "Call logged: Voicemail. Moved to Not interested after three unanswered calls." }

    assert_selector "[role=alert][aria-label='Not interested warning']", text: "Not interested - do not contact"
    assert_selector ".timeline", text: "Moved to Not interested automatically after three unanswered calls"
    assert lead.reload.not_interested?
    assert_not lead.unsure?

    visit leads_path(tab: "unsure", q: lead.name)
    assert_no_link lead.name
    visit leads_path(tab: "not_interested", q: lead.name)
    assert_link lead.name

    within("li", text: lead.name) { click_button "Interested again" }
    assert_no_link lead.name
    visit leads_path(tab: "unsure", q: lead.name)
    assert_link lead.name
    assert lead.reload.unsure?
    assert_not lead.not_interested?
  end

  test "three unanswered attempts on an Unsure ad lead move it to Re-contact with a timeline note and supports manual undo" do
    lead = Lead.create!(name: "Ad Lead System", email: "ad-three-sys@example.com", source: "meta_ads")
    lead.mark_unsure!
    CallLog.record!(lead, key: "sys-ad-1", occurred_at: 3.days.ago, outcome: "voicemail", direction: "outbound")
    CallLog.record!(lead, key: "sys-ad-2", occurred_at: 2.days.ago, outcome: "no_answer", direction: "outbound")

    visit lead_path(lead, return_to: leads_path(tab: "unsure"))
    within(".calls") do
      tolerate_submit_navigation { click_button "Voicemail" }
    end
    tolerate_navigation_assertion { assert_text "Call logged: Voicemail. Moved to Re-contact after three unanswered calls." }

    assert_selector "[role=region][aria-label='Re-contact list']", text: "Re-contact list"
    assert_selector ".timeline", text: "Moved to Re-contact automatically after three unanswered calls"
    assert_selector "[data-missed-call-reminder]", text: "send a short text by hand"
    assert lead.reload.recontact?
    assert_not lead.not_interested?

    visit leads_path(tab: "recontact", q: lead.name)
    assert_link lead.name
    within("li", text: lead.name) { click_button "Restore from Re-contact" }
    assert_no_link lead.name
    visit leads_path(tab: "unsure", q: lead.name)
    assert_link lead.name
    assert lead.reload.unsure?
    assert_not lead.recontact?
  end

  test "a second missed call on a website lead shows Text 2 to copy at desktop and phone width" do
    travel_to Date.current.next_occurring(:wednesday).in_time_zone.change(hour: 10)
    lead = Lead.create!(name: "Website System", email: "web-sys@example.com", phone: "+14155550203", source: "website_form",
      trip_title: "Annapurna Circuit")
    CallLog.record!(lead, key: "sys-web-1", occurred_at: 1.day.ago, outcome: "voicemail", direction: "outbound")
    text2 = "Hi Website, it's Sam at SherpaHolidays again about your Annapurna Circuit inquiry. Would Thursday morning or " \
      "afternoon suit you for a short call? A quick reply here works too."

    visit lead_path(lead)
    within(".calls") do
      tolerate_submit_navigation { click_button "No answer" }
    end
    tolerate_navigation_assertion { assert_text "Call logged: No answer. Send a short text by hand. Attempt 2 of 3 logged" }
    within("[data-missed-call-reminder]") do
      assert_selector "[data-missed-call-text-label]", text: "Text 2"
      assert_equal text2, find("textarea[aria-label='Text 2 to send by hand']").value
      click_button "Copy text"
      assert_selector "[role=status]", text: /Message copied\.|Select and copy the message below\./
    end
    capture_calls("text-2-desktop")

    page.current_window.resize_to(390, 844)
    visit lead_path(lead, anchor: "record-details")
    within("[data-missed-call-reminder]") do
      assert_selector "[data-missed-call-text-label]", text: "Text 2"
      assert_equal text2, find("textarea[aria-label='Text 2 to send by hand']").value
      assert_button "Copy text"
    end
    capture_calls("text-2-phone")
    assert_operator page.evaluate_script("document.documentElement.scrollWidth"), :<=, 390
  ensure
    travel_back
  end

  def capture_calls(name)
    return unless ENV["CALL_BUTTONS_EVIDENCE"]

    find(".calls").execute_script("this.scrollIntoView({block: 'center'})")
    page.save_screenshot(File.join(ENV.fetch("CALL_BUTTONS_EVIDENCE"), "#{name}.png"))
  end
end
