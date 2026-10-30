require "application_system_test_case"
require_relative "../support/google_sign_in_test_helper"

# Leads live on the phone too: create, note, and convert must work at 390px.
class LeadsSystemTest < ApplicationSystemTestCase
  include GoogleSignInTestHelper

  test "lead detail hides fit card at desktop and phone widths" do
    OmniAuth.config.mock_auth[:google_oauth2] = OmniAuth::AuthHash.new(
      provider: "google_oauth2", uid: "google-captain",
      extra: { id_token: JWT.encode(@claims, @key, "RS256") }
    )
    Google::Auth::IDTokens.stub(:oidc_key_source, @source) do
      visit "/auth/google_oauth2/callback"
      assert_selector "h1", text: "Today"
    end

    [ 1440, 390 ].each do |width|
      lead = Lead.create!(name: "Unscored at #{width}")
      page.current_window.resize_to(width, 900)
      visit lead_path(lead)
      click_button "Details", exact: true if width == 390
      assert_no_selector ".fit-head"
      assert_no_text "Set your fit"
      assert_operator page.evaluate_script("document.documentElement.scrollWidth"), :<=, width
    end
  end

  test "create lead with note and convert at phone width" do
    OmniAuth.config.mock_auth[:google_oauth2] = OmniAuth::AuthHash.new(
      provider: "google_oauth2", uid: "google-captain",
      extra: { id_token: JWT.encode(@claims, @key, "RS256") }
    )
    Google::Auth::IDTokens.stub(:oidc_key_source, @source) do
      visit "/auth/google_oauth2/callback"
      assert_selector "h1", text: "Today"
    end
    page.current_window.resize_to(390, 844)

    visit leads_path
    assert_selector "h1", text: "Leads"
    assert_no_overflow("/leads")

    click_link "New lead"
    assert_selector "h1", text: "New lead"

    fill_in "Display name", with: "Ad Tashi"
    select "Google ads", from: "Source"
    fill_in "Campaign", with: "Everest Spring"
    click_button "Save lead"
    assert_selector "h1", text: "Ad Tashi"
    assert_no_overflow("lead page")

    # The composer hides behind the Reply pill on the phone and notes live
    # in its Note mode: open the pill, switch modes, then write.
    click_button "Reply"
    choose "Note", allow_label_click: true
    fill_in "Add a note", with: "Clicked the Everest ad"
    # The fixed phone tab bar can cover the button's click point after the
    # auto-scroll; center it first (same pattern as inbox_system_test.rb).
    save_note = find_button("Save note")
    save_note.scroll_to(save_note, align: :center)
    save_note.click
    assert_text "Clicked the Everest ad"
    assert_no_overflow("lead page after note")

    accept_confirm do
      click_button "Convert to client"
    end
    assert_selector "h1", text: "Ad Tashi"
    assert_text "Started as a lead"
    assert_no_overflow("converted client page")

    click_button "Details", exact: true
    click_link "open it"
    assert_text "Converted leads stay read-only."
    assert_no_button "Convert to client"
    assert_no_link "Edit"
    visit "#{page.current_path}/edit"
    assert_text "Converted leads stay read-only."
    assert_no_button "Save lead"
    assert_no_link "Edit"
  end

  test "delete archives with one confirmation and the archived tab restores" do
    OmniAuth.config.mock_auth[:google_oauth2] = OmniAuth::AuthHash.new(
      provider: "google_oauth2", uid: "google-captain",
      extra: { id_token: JWT.encode(@claims, @key, "RS256") }
    )
    Google::Auth::IDTokens.stub(:oidc_key_source, @source) do
      visit "/auth/google_oauth2/callback"
      assert_selector "h1", text: "Today"
    end
    page.current_window.resize_to(1400, 900)

    lead = Lead.create!(name: "Archive Tashi", source: "manual", status: "chatting")
    visit lead_path(lead)
    assert_selector "h1", text: "Archive Tashi"

    find("summary[aria-label='More actions']").click
    accept_confirm "Delete Archive Tashi? They move to the archive and can be restored from the Archived tab." do
      click_button "Delete lead"
    end
    assert_selector "h2", text: "New"
    assert_no_text "Archive Tashi"
    visit leads_path(tab: "archived")
    assert_text "Archive Tashi"

    visit leads_path(tab: "new")
    assert_no_text "Archive Tashi"

    visit leads_path(tab: "archived")
    click_button "Restore"
    assert_selector "h2", text: "Archived"
    assert_no_text "Archive Tashi"
    visit leads_path(tab: "new")
    assert_text "Archive Tashi"
  end

  test "opening a lead and going back keeps the same lead area in view across tabs, filters, and widths" do
    OmniAuth.config.mock_auth[:google_oauth2] = OmniAuth::AuthHash.new(
      provider: "google_oauth2", uid: "google-captain",
      extra: { id_token: JWT.encode(@claims, @key, "RS256") }
    )
    Google::Auth::IDTokens.stub(:oidc_key_source, @source) do
      visit "/auth/google_oauth2/callback"
      assert_selector "h1", text: "Today"
    end

    new_leads = (1..24).map do |i|
      lead = Lead.create!(
        name: format("Scroll New %02d", i),
        source: "website_form",
        campaign_name: "scroll-check",
        status: "new"
      )
      lead.update_column(:last_activity_at, i.minutes.ago)
      lead
    end
    potential_leads = (1..24).map do |i|
      lead = Lead.create!(
        name: format("Scroll Potential %02d", i),
        source: "website_form",
        campaign_name: "scroll-check",
        status: "new"
      )
      lead.mark_potential!
      lead.update_column(:last_activity_at, i.minutes.ago)
      lead
    end

    target_new = new_leads[18]
    target_potential = potential_leads[18]

    [ [ 1400, 900 ], [ 390, 844 ] ].each do |width, height|
      page.current_window.resize_to(width, height)

      visit leads_path(tab: "new")
      assert_selector "h2", text: "New", exact_text: true
      link = find_link(target_new.name)
      page.execute_script("arguments[0].scrollIntoView({ block: 'center' })", link)
      before_scroll_y = page.evaluate_script("window.scrollY")
      before_top = link.evaluate_script("this.getBoundingClientRect().top")
      assert_operator before_scroll_y, :>, 600

      link.click
      assert_selector "h1", text: target_new.name
      page.go_back
      assert_selector "h2", text: "New", exact_text: true
      assert_in_delta before_scroll_y, page.evaluate_script("window.scrollY"), 5
      assert_in_delta before_top, find_link(target_new.name).evaluate_script("this.getBoundingClientRect().top"), 5

      find_link(target_new.name).click
      assert_selector "h1", text: target_new.name
      within("header.page-header") { click_link "Leads" }
      assert_selector "h2", text: "New", exact_text: true
      assert_in_delta before_scroll_y, page.evaluate_script("window.scrollY"), 5
      assert_in_delta before_top, find_link(target_new.name).evaluate_script("this.getBoundingClientRect().top"), 5

      visit leads_path(tab: "potential", q: "Scroll Potential", sort: "name")
      assert_selector "h2", text: "Potential", exact_text: true
      pot_link = find_link(target_potential.name)
      page.execute_script("arguments[0].scrollIntoView({ block: 'center' })", pot_link)
      pot_scroll_y = page.evaluate_script("window.scrollY")
      pot_top = pot_link.evaluate_script("this.getBoundingClientRect().top")
      assert_operator pot_scroll_y, :>, 600

      pot_link.click
      assert_selector "h1", text: target_potential.name
      if width == 1400
        click_link "Edit details"
        assert_selector "h1", text: "Edit lead"
        click_button "Save changes"
      else
        click_link "Edit"
        assert_selector "h1", text: "Edit lead"
        click_link "Cancel"
      end
      assert_selector "h1", text: target_potential.name
      within("header.page-header") { click_link "Leads" }
      assert_selector "h2", text: "Potential", exact_text: true
      assert_in_delta pot_scroll_y, page.evaluate_script("window.scrollY"), 5
      assert_in_delta pot_top, find_link(target_potential.name).evaluate_script("this.getBoundingClientRect().top"), 5
    end
  end

  private

  def assert_no_overflow(context)
    width = page.evaluate_script("document.documentElement.scrollWidth")
    assert_operator width, :<=, 390, "#{context} overflows a 390px viewport (#{width}px)"
  end
end
