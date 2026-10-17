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
    assert_text "Call logged: Talked."
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

  def capture_calls(name)
    return unless ENV["CALL_BUTTONS_EVIDENCE"]

    find(".calls").execute_script("this.scrollIntoView({block: 'center'})")
    page.save_screenshot(File.join(ENV.fetch("CALL_BUTTONS_EVIDENCE"), "#{name}.png"))
  end
end
