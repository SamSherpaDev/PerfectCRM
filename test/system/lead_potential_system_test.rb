require "application_system_test_case"
require_relative "../support/google_sign_in_test_helper"

class LeadPotentialSystemTest < ApplicationSystemTestCase
  include GoogleSignInTestHelper

  test "owner manages potential reminders on desktop and phone" do
    OmniAuth.config.mock_auth[:google_oauth2] = OmniAuth::AuthHash.new(
      provider: "google_oauth2", uid: "google-captain",
      extra: { id_token: JWT.encode(@claims, @key, "RS256") }
    )
    Google::Auth::IDTokens.stub(:oidc_key_source, @source) do
      visit "/auth/google_oauth2/callback"
      assert_selector "h1", text: "Today"
    end

    [ 1400, 390 ].each do |width|
      page.current_window.resize_to(width, 900)
      lead = Lead.create!(name: "Potential traveler #{width}", status: "chatting", owner_fit_at_inquiry: "possible")
      general = Lead.create!(name: "Unmarkedguest#{width}")
      visit lead_path(lead)
      click_button "Mark Potential", exact: true
      assert_button "Remove Potential"
      assert_equal "chatting", lead.reload.status
      assert_equal "possible", lead.owner_fit_at_inquiry
      visit leads_path(tab: "potential")
      assert_link lead.name
      assert_no_link general.name
      page.execute_script("arguments[0].scrollIntoView({block: 'center'})", find_link(lead.name)) if width == 390
      assert_operator page.evaluate_script("document.documentElement.scrollWidth"), :<=, width
      visit leads_path(tab: "chatting")
      within("li", text: lead.name) { assert_button "Remove Potential" }
      visit leads_path(tab: "potential", q: general.name)
      assert_text "No matches"
      visit leads_path(tab: "potential", q: lead.name, sort: "name")
      assert_link lead.name
      click_button "Remove Potential"
      assert_no_link lead.name
      assert_nil lead.reload.potential_marked_at
      visit leads_path(tab: "chatting")
      within("li", text: lead.name) { click_button "Mark Potential" }
      assert_button "Remove Potential"
      assert lead.reload.potential?
      visit lead_path(lead)
      click_button "Mark as spam"
      assert_no_button "Remove Potential"
      assert lead.reload.archived?
      assert_nil lead.potential_marked_at
      visit leads_path(tab: "potential")
      assert_no_link lead.name
      visit lead_path(lead)
      assert_no_button "Mark Potential"
      click_button "Not spam"
      assert_button "Mark Potential"
      assert_not lead.reload.potential?
      visit lead_path(lead)
      click_button "Mark Potential"
      accept_confirm { click_button "Convert to client" }
      assert_selector "h1", text: lead.name
      visit leads_path(tab: "potential")
      assert_no_link lead.name
      visit lead_path(lead)
      assert_no_button "Mark Potential"
      assert_no_button "Remove Potential"
      flagged = Lead.create!(name: "Flagged #{width}", tag_list: Lead::SUSPECTED_SPAM_TAG)
      archived = Lead.create!(name: "Archived #{width}", archived_at: Time.current)
      [ lead, flagged, archived ].each do |blocked|
        visit lead_path(blocked)
        assert_no_button "Mark Potential"
        page.execute_script(<<~JS, mark_potential_lead_path(blocked))
          const form = document.createElement("form");
          form.method = "post"; form.action = arguments[0];
          const method = document.createElement("input");
          method.name = "_method"; method.value = "patch";
          form.append(method); document.body.append(form); form.submit();
        JS
        assert_text "Only active, non-spam leads can be marked Potential"
        assert_nil blocked.reload.potential_marked_at unless blocked == lead
        assert_not blocked.reload.potential?
      end
    end
  end
end
