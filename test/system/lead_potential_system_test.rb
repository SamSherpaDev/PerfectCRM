require "application_system_test_case"
require_relative "../support/google_sign_in_test_helper"

class LeadPotentialSystemTest < ApplicationSystemTestCase
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
  end

  test "reviewed leads leave New immediately on desktop and phone" do
    [ 1400, 390 ].each do |width|
      page.current_window.resize_to(width, 900)
      potential = Lead.create!(name: "Routing#{width} Potential")
      spam = Lead.create!(name: "Routing#{width} Spam")
      waiting = Lead.create!(name: "Routing#{width} Waiting")
      visit leads_path(tab: "new", q: "Routing#{width}", sort: "name")
      within("li", text: potential.name) { click_button "Mark Potential" }
      assert_selector "h2", text: "New", exact_text: true
      assert_no_link potential.name
      assert_link waiting.name
      assert_link spam.name
      within("nav.tabs") { click_link "Potential" }
      assert_link potential.name
      assert_no_link spam.name
      within("nav.tabs") { click_link "New" }
      assert_no_link potential.name
      within("li", text: spam.name) { click_button "Mark as spam" }
      assert_selector "h2", text: "Archived", exact_text: true
      assert_link spam.name
      within("nav.tabs") { click_link "New" }
      assert_no_link spam.name
      assert_no_link potential.name
      assert_link waiting.name
      assert_operator page.evaluate_script("document.documentElement.scrollWidth"), :<=, width
    end
  end

  test "unsure leads leave New and move on once known on desktop and phone" do
    [ 1400, 390 ].each do |width|
      page.current_window.resize_to(width, 900)
      unsure = Lead.create!(name: "Sorting#{width} Voicemail", tag_list: Lead::SUSPECTED_SPAM_TAG)
      waiting = Lead.create!(name: "Sorting#{width} Waiting")
      chatting = Lead.create!(name: "Sorting#{width} Chatting", status: "chatting")
      visit leads_path(tab: "new", q: "Sorting#{width}", sort: "name")
      assert_equal %w[New Potential Unsure Quoted Converted Archived],
        all("nav.tabs a").map { |tab| tab.first("span").text }
      assert_link chatting.name
      capture("new-#{width}")
      within("li", text: unsure.name) { click_button "Mark Unsure" }
      assert_selector "h2", text: "New", exact_text: true
      assert_no_link unsure.name
      assert_link waiting.name
      within("nav.tabs") { click_link "Unsure" }
      assert_selector "h2", text: "Unsure", exact_text: true
      assert_link unsure.name
      assert_no_link waiting.name
      within("li", text: unsure.name) { assert_button "Remove Unsure" }
      assert_operator page.evaluate_script("document.documentElement.scrollWidth"), :<=, width
      capture("unsure-#{width}")
      within("li", text: unsure.name) { click_button "Not spam" }
      visit lead_path(unsure)
      assert_button "Remove Unsure"
      assert_operator page.evaluate_script("document.documentElement.scrollWidth"), :<=, width
      capture("lead-#{width}")
      click_button "Mark Potential", exact: true
      assert_button "Remove Potential"
      assert_button "Mark Unsure"
      visit leads_path(tab: "unsure", q: "Sorting#{width}")
      assert_no_link unsure.name
      visit leads_path(tab: "potential", q: "Sorting#{width}")
      assert_link unsure.name
    end
  end

  test "owner manages potential reminders on desktop and phone" do
    [ 1400, 390 ].each do |width|
      page.current_window.resize_to(width, 900)
      lead = Lead.create!(name: "Potential traveler #{width}", status: "quoted", owner_fit_at_inquiry: "possible")
      general = Lead.create!(name: "Unmarkedguest#{width}")
      visit lead_path(lead)
      click_button "Mark Potential", exact: true
      assert_button "Remove Potential"
      assert_equal "quoted", lead.reload.status
      assert_equal "possible", lead.owner_fit_at_inquiry
      visit leads_path(tab: "potential")
      assert_link lead.name
      assert_no_link general.name
      page.execute_script("arguments[0].scrollIntoView({block: 'center'})", find_link(lead.name)) if width == 390
      assert_operator page.evaluate_script("document.documentElement.scrollWidth"), :<=, width
      visit leads_path(tab: "quoted")
      within("li", text: lead.name) { assert_button "Remove Potential" }
      visit leads_path(tab: "potential", q: general.name)
      assert_text "No matches"
      visit leads_path(tab: "potential", q: lead.name, sort: "name")
      assert_link lead.name
      click_button "Remove Potential"
      assert_no_link lead.name
      assert_nil lead.reload.potential_marked_at
      visit leads_path(tab: "quoted")
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

  test "unsure can be removed or resolved as spam and rejects inactive leads" do
    page.current_window.resize_to(390, 900)
    lead = Lead.create!(name: "Unanswered traveler")
    visit lead_path(lead)
    click_button "Mark Unsure"
    assert_button "Remove Unsure"
    visit leads_path(tab: "unsure", q: lead.name)
    click_button "Remove Unsure"
    assert_no_link lead.name
    visit leads_path(tab: "new", q: lead.name)
    assert_link lead.name
    within("li", text: lead.name) { click_button "Mark Potential" }
    visit lead_path(lead)
    click_button "Mark Unsure"
    assert_button "Mark Potential"
    assert_button "Remove Unsure"
    click_button "Mark as spam"
    assert_no_button "Mark Unsure"
    assert_nil lead.reload.unsure_marked_at
    visit leads_path(tab: "unsure", q: lead.name)
    assert_no_link lead.name
    converted = Lead.create!(name: "Converted traveler")
    converted.convert_to_client!
    [ lead, converted ].each do |blocked|
      visit lead_path(blocked)
      assert_no_button "Mark Unsure"
      page.execute_script(<<~JS, mark_unsure_lead_path(blocked))
        const form = document.createElement("form");
        form.method = "post"; form.action = arguments[0];
        const method = document.createElement("input");
        method.name = "_method"; method.value = "patch";
        form.append(method); document.body.append(form); form.submit();
      JS
      assert_text "Only active leads not marked as spam can be marked Unsure"
      assert_nil blocked.reload.unsure_marked_at
    end
    capture("unsure-guard-phone")
  end

  test "old stage links preserve search and reveal the selected phone tab" do
    page.current_window.resize_to(390, 900)
    %w[chatting nudged lost].each do |stage|
      attrs = { name: "Legacy #{stage}", status: stage }
      attrs[:lost_reason] = "no_reply" if stage == "lost"
      lead = Lead.create!(attrs)
      visit leads_path(tab: stage, q: "Legacy", sort: "name")
      home = stage == "lost" ? "archived" : "new"
      assert_current_path leads_path(q: "Legacy", sort: "name", tab: home)
      assert_link lead.name
      current = find("nav.tabs [aria-current]")
      assert_equal home.capitalize, current.first("span").text
      assert current.evaluate_script(<<~JS)
        (() => { const tab = this.getBoundingClientRect();
          const row = this.parentElement.getBoundingClientRect();
          return tab.left >= row.left - 1 && tab.right <= row.right + 1; })()
      JS
      assert_operator page.evaluate_script("document.documentElement.scrollWidth"), :<=, 390
      capture("legacy-#{stage}-phone")
    end
  end

  private

  def capture(name)
    return unless ENV["LEAD_TABS_EVIDENCE"]

    page.save_screenshot(File.join(ENV.fetch("LEAD_TABS_EVIDENCE"), "#{name}.png"))
  end
end
