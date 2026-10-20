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
      second_spam = Lead.create!(name: "Routing#{width} Second spam")
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
      assert_selector "h2", text: "New", exact_text: true
      assert_no_link spam.name
      assert_link second_spam.name
      within("li", text: second_spam.name) { click_button "Mark as spam" }
      assert_selector "h2", text: "New", exact_text: true
      assert_no_link second_spam.name
      within("nav.tabs") { click_link "Archived" }
      assert_selector "h2", text: "Archived", exact_text: true
      assert_link spam.name
      assert_link second_spam.name
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
      assert_equal [ "New", "Potential", "Unsure", "Quoted", "Not interested", "Archived" ],
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
      visit lead_path(unsure)
      assert_button "Remove Unsure"
      assert_operator page.evaluate_script("document.documentElement.scrollWidth"), :<=, width
      capture("unsure-#{width}")
      click_button "Not spam"
      assert_current_path leads_path(tab: "new")
      visit lead_path(unsure)
      assert_button "Remove Unsure"
      assert_operator page.evaluate_script("document.documentElement.scrollWidth"), :<=, width
      capture("lead-#{width}")
      click_button "Mark Potential", exact: true
      assert_current_path leads_path(tab: "new")
      visit lead_path(unsure)
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
      assert_current_path leads_path(tab: "new")
      visit lead_path(lead)
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
      assert_current_path leads_path(tab: "new")
      assert_no_button "Remove Potential"
      assert lead.reload.archived?
      assert_nil lead.potential_marked_at
      visit leads_path(tab: "potential")
      assert_no_link lead.name
      visit lead_path(lead)
      assert_no_button "Mark Potential"
      click_button "Not spam"
      assert_current_path leads_path(tab: "new")
      visit lead_path(lead)
      assert_button "Mark Potential"
      assert_not lead.reload.potential?
      visit lead_path(lead)
      click_button "Mark Potential"
      visit lead_path(lead)
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
    assert_current_path leads_path(tab: "new")
    visit lead_path(lead)
    assert_button "Remove Unsure"
    visit leads_path(tab: "unsure", q: lead.name)
    click_button "Remove Unsure"
    assert_no_link lead.name
    visit leads_path(tab: "new", q: lead.name)
    assert_link lead.name
    within("li", text: lead.name) { click_button "Mark Potential" }
    visit lead_path(lead)
    click_button "Mark Unsure"
    assert_current_path leads_path(tab: "new")
    visit lead_path(lead)
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

  test "quoted stays visible and converted leads move to Clients without breaking old links" do
    [ 1400, 390 ].each do |width|
      page.current_window.resize_to(width, 900)
      lead = Lead.create!(name: "Tab traveler #{width}", status: "quoted", source: "manual")
      visit leads_path
      assert_equal [ "New", "Potential", "Unsure", "Quoted", "Not interested", "Archived" ],
        all("nav.tabs a").map { |tab| tab.first("span").text }
      within("nav.tabs") { click_link "Quoted" }
      assert_link lead.name
      assert_operator page.evaluate_script("document.documentElement.scrollWidth"), :<=, width
      find_link(lead.name).scroll_to(:center) if width == 390
      capture("quoted-kept-#{width}")
      click_link lead.name
      accept_confirm { click_button "Convert to client" }
      assert_selector "h1", text: lead.name
      assert_text "Started as a lead"
      %w[new potential unsure quoted not_interested archived].each do |tab|
        visit leads_path(tab: tab, q: lead.name)
        assert_no_link lead.name
      end
      visit leads_path(tab: "converted", q: lead.name, sort: "name")
      assert_current_path leads_path(q: lead.name, sort: "name", tab: "new")
      assert_selector "h2", text: "New", exact_text: true
      assert_no_link lead.name
      capture("converted-redirect-#{width}")
      visit clients_path(q: lead.name)
      assert_link lead.name
      click_link lead.name
      assert_selector "h1", text: lead.name
      click_button "Details", exact: true if width == 390
      assert_link "open it", href: lead_path(lead)
      find_link("open it").scroll_to(:center) if width == 390
      capture("converted-client-#{width}")
      click_link "open it"
      assert_text "Converted leads stay read-only."
      assert_no_button "Convert to client"
    end
  end

  test "not interested leads show warning banner, require confirm before emailing or calling, and restore to previous tab on desktop and phone" do
    [ 1400, 390 ].each do |width|
      page.current_window.resize_to(width, 900)
      lead = Lead.create!(name: "Declined #{width}", email: "declined-#{width}@example.com", source: "google_ads", status: "new")
      lead.mark_potential!
      convo = lead.conversations.create!(subject: "Everest trek")
      convo.messages.create!(direction: "in", from_address: lead.email, to_addresses: [ "info@sherpaholidays.com" ],
        subject: "Everest trek", text_body: "Not interested right now", sent_at: 1.hour.ago, status: "received")
      lead.scheduled_calls.create!(scheduled_at: 2.days.from_now.change(hour: 11, min: 0), duration_minutes: 30)

      visit leads_path(tab: "potential", q: "Declined #{width}", sort: "name")
      within("li", text: lead.name) { click_button "Mark not interested" }
      assert_selector "h2", text: "Potential", exact_text: true
      assert_no_link lead.name
      within("nav.tabs") { click_link "Not interested" }
      assert_selector "h2", text: "Not interested", exact_text: true
      assert_link lead.name
      within("li", text: lead.name) { assert_button "Interested again" }
      assert_operator page.evaluate_script("document.documentElement.scrollWidth"), :<=, width

      click_link lead.name
      assert_selector "[role=alert][aria-label='Not interested warning']", text: "Not interested - do not contact"
      assert_text "Scheduled call for"
      assert_text "cancelled (marked not interested)"
      assert_operator page.evaluate_script("document.documentElement.scrollWidth"), :<=, width

      # Dismissing email confirm prevents sending; dismissing call confirm prevents logging an outbound call; accepting logs it
      click_button "Reply" if width == 390
      fill_in "Message", with: "Just following up."
      details = find(".reply-details")
      details.find("summary").click unless details["open"] == "true"
      fill_in "To", with: lead.email
      assert_no_difference -> { Message.outbound.count } do
        dismiss_confirm("This lead is marked not interested. Send this email anyway?") do
          click_button "Send"
        end
      end
      click_button "Close" if width == 390

      click_button "Details", exact: true if width == 390
      assert_no_difference -> { lead.activity_events.where(kind: "call").count } do
        dismiss_confirm("This lead is marked not interested. Log an outbound call anyway?") do
          within(".calls") { click_button "No answer" }
        end
      end
      assert_difference -> { lead.activity_events.where(kind: "call").count }, 1 do
        accept_confirm("This lead is marked not interested. Log an outbound call anyway?") do
          within(".calls") { click_button "No answer" }
        end
        assert_selector ".flash-notice", text: "Call logged: No answer."
      end
      within(".calls") do
        find("summary", text: "Add details").click
        assert_no_difference -> { lead.activity_events.where(kind: "call").count } do
          dismiss_confirm("This lead is marked not interested. Log an outbound call anyway?") do
            click_button "Save call"
          end
        end
      end

      # Undo returns the lead to Potential
      click_button "Interested again"
      assert_current_path leads_path(tab: "new")
      visit leads_path(tab: "not_interested", q: "Declined #{width}", sort: "name")
      assert_no_link lead.name
      within("nav.tabs") { click_link "Potential" }
      assert_link lead.name
    end
  end

  private

  def capture(name)
    return unless ENV["LEAD_TABS_EVIDENCE"]

    page.save_screenshot(File.join(ENV.fetch("LEAD_TABS_EVIDENCE"), "#{name}.png"))
  end
end
