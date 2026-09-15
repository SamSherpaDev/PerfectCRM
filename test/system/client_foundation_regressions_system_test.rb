require "application_system_test_case"
require_relative "../support/google_sign_in_test_helper"

class ClientFoundationRegressionsSystemTest < ApplicationSystemTestCase
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
    page.current_window.resize_to(390, 844)
  end

  test "traveler emails can be reassigned and duplicates show errors for both owner types" do
    [Client, Lead].each do |model|
      record = model.create!(name: "Everest family")
      one = record.people.create!(name: "First", email: "one@example.com")
      two = record.people.create!(name: "Second", email: "two@example.com")
      key = model.model_name.param_key
      visit polymorphic_path(record, action: :edit)
      fill_in "#{key}[people_attributes][0][email]", with: "two@example.com"
      fill_in "#{key}[people_attributes][1][email]", with: ""
      fill_in "#{key}[people_attributes][2][name]", with: "Third"
      fill_in "#{key}[people_attributes][2][email]", with: "third@example.com"
      click_button "Save changes"
      assert_selector "h1", text: record.name
      assert_text "Third"
      assert_equal "two@example.com", one.reload.email
      assert_nil two.reload.email
      visit polymorphic_path(record, action: :edit)
      fill_in "#{key}[people_attributes][1][email]", with: "two@example.com"
      click_button "Save changes"
      assert_selector "[role=alert]", text: /email/i
      capture("#{key}-duplicate-error")
      fill_in "#{key}[people_attributes][1][email]", with: ""
      fill_in "Tags", with: "x" * 41
      click_button "Save changes"
      assert_selector "[role=alert]", text: /tag/i
    end
  end

  test "organization creation and notes work on a phone" do
    visit new_organization_path
    fill_in "Name", with: "Himalayan Operations"
    select "Operator", from: "Kind"
    fill_in "Email", with: "ops@example.com"
    fill_in "Tags", with: "nepal"
    fill_in "PerfectBook contact id", with: "456"
    click_button "Save organization"
    assert_selector "h1", text: "Himalayan Operations"
    fill_in "Add a note", with: "Runs our Nepal departures"
    click_button "Save note"
    assert_text "Runs our Nepal departures"
    capture("organization-phone")
    visit clients_path(tab: "organizations")
    assert_link "Himalayan Operations"
    assert_selector "a[href='https://perfectbook.sherpaholidays.com/contacts/456']"
    capture("organizations-phone")
  end

  test "supplied fit band and full history survive one way conversion" do
    lead = Lead.create!(name: "Everest inquiry", source: "meta_ads", campaign_name: "Spring 2027", fit_score: 80, fit_band: "possible", tag_list: "everest", perfectbook_contact_id: 123)
    lead.people.create!(name: "Maya", email: "maya@example.com")
    note = lead.notes.create!(body: "Two travelers for May")
    lead.activity_events.create!(kind: "automation", summary: "Panda qualification received", occurred_at: Time.current)
    visit leads_path
    assert_text "Possible"
    assert_no_text "Unanswered"
    capture("leads-phone")
    visit lead_path(lead)
    assert_text "maya@example.com"
    capture("lead-phone")
    accept_confirm { click_button "Convert to client" }
    assert_text "Started as a lead"
    assert_text "Spring 2027"
    assert_text "Panda qualification received"
    client = lead.reload.converted_client
    assert_equal "meta_ads", client.source
    assert_equal "Spring 2027", client.campaign_name
    assert_equal 1, client.activity_events.where(kind: "note").count
    assert_equal client.notes.first.id, client.activity_events.find_by!(kind: "note").metadata["note_id"]
    capture("converted-client-phone")
    visit edit_lead_path(lead)
    assert_text "Converted leads stay read-only"
    assert_no_button "Convert to client"
    assert_no_button "Save note"
    visit clients_path
    assert_selector "a[href='https://perfectbook.sherpaholidays.com/contacts/123']"
    capture("clients-phone")
    visit client_path(client)
    accept_confirm { click_button "Archive" }
    assert_text "Client archived."
    click_link client.name
    assert_button "Restore"
    click_button "Restore"
    assert_button "Archive"
  end

  test "older notes and activity are reachable on every record type" do
    [Client, Lead, Organization].each do |model|
      record = model.create!(name: "Long history")
      51.times { |i| record.notes.create!(body: "Historic note #{i}", created_at: i.minutes.ago) }
      51.times { |i| record.activity_events.create!(kind: "email", summary: "Historic email #{i}", occurred_at: i.days.ago) }
      visit polymorphic_path(record)
      click_link "Older notes"
      assert_text "Historic note 50"
      click_link "Older activity"
      assert_text "Historic email 50"
      capture("#{model.model_name.param_key}-older-history")
    end
  end

  test "search sorting and export operate through the running application" do
    [Client, Lead, Organization].each do |model|
      model.create!(name: "Match Alpha")
      model.create!(name: "Match Zulu")
      visit(model == Lead ? leads_path : clients_path(tab: model == Organization ? "organizations" : "clients"))
      fill_in(model == Lead ? "Search leads" : "Search clients", with: "Match")
      click_button "Search"
      select "Name", from: "sort"
      assert_selector "select option[selected][value=name]"
      assert_equal ["Match Alpha", "Match Zulu"], all("main a").map(&:text).select { |text| text.start_with?("Match") }
    end
    client = Client.create!(name: "=SUM(1,2)", phone: "+123456", tag_list: "@tag")
    client.notes.create!(body: "=1+1")
    visit edit_settings_path
    assert_link "Export everything"
    capture("export-settings-phone")
    result = page.evaluate_async_script(<<~JS)
      const done = arguments[arguments.length - 1];
      fetch(document.querySelector('a[href="/settings/export"]').href).then(async response => {
        const bytes = new Uint8Array(await response.arrayBuffer());
        done({status: response.status, data: btoa(Array.from(bytes, b => String.fromCharCode(b)).join(''))});
      }).catch(error => done({error: String(error)}));
    JS
    assert_equal 200, result["status"]
    bytes = Base64.decode64(result.fetch("data"))
    File.binwrite(File.join(ENV["CRM_EVIDENCE_DIR"], "crm-export.zip"), bytes) if ENV["CRM_EVIDENCE_DIR"]
    tables = {}
    Zip::InputStream.open(StringIO.new(bytes)) do |zip|
      while (entry = zip.get_next_entry)
        tables[entry.name] = CSV.parse(zip.read.force_encoding(Encoding::UTF_8).delete_prefix("\uFEFF"), headers: true)
      end
    end
    assert_equal %w[activity_events.csv clients.csv leads.csv notes.csv organizations.csv people.csv taggings.csv tags.csv], tables.keys.sort
    row = tables["clients.csv"].find { |r| r["id"] == client.id.to_s }
    assert_equal "'=SUM(1,2)", row["name"]
    assert_equal "'+123456", row["phone"]
    assert_equal "'=1+1", tables["notes.csv"].first["body"]
    assert_equal "'@tag", tables["tags.csv"].first["name"]
    assert_equal client.id.to_s, tables["taggings.csv"].first["taggable_id"]
    assert_equal "note", tables["activity_events.csv"].find { |r| r["subject_id"] == client.id.to_s && r["kind"] == "note" }["kind"]
  end

  test "repeated conversion and subsequent writes cannot mutate a converted lead" do
    lead = Lead.create!(name: "Concurrent inquiry")
    visit lead_path(lead)
    before = Client.count
    result = page.evaluate_async_script(<<~JS, convert_lead_path(lead))
      const path = arguments[0], done = arguments[arguments.length - 1];
      const headers = {'X-CSRF-Token': document.querySelector('meta[name="csrf-token"]')?.content || ''};
      Promise.all([fetch(path, {method: 'POST', headers}), fetch(path, {method: 'POST', headers})])
        .then(responses => done(responses.map(r => r.status))).catch(e => done(String(e)));
    JS
    assert_equal [200, 200], result
    assert_equal before + 1, Client.count
    assert lead.reload.converted?
    result = page.evaluate_async_script(<<~JS, lead_path(lead), lead_notes_path(lead))
      const leadPath = arguments[0], notePath = arguments[1], done = arguments[arguments.length - 1];
      const headers = {'Content-Type': 'application/x-www-form-urlencoded', 'X-CSRF-Token': document.querySelector('meta[name="csrf-token"]')?.content || ''};
      Promise.all([fetch(leadPath, {method: 'POST', headers, body: '_method=patch&lead[name]=Late+edit'}),
        fetch(notePath, {method: 'POST', headers, body: 'note[body]=Late+note'})])
        .then(responses => done(responses.map(r => r.status))).catch(e => done(String(e)));
    JS
    assert_equal [200, 200], result
    assert_equal "Concurrent inquiry", lead.reload.name
    assert_empty lead.notes
    assert_empty lead.converted_client.notes
    visit lead_path(lead)
    assert_no_button "Save note"
    capture("converted-lead-readonly-phone")
  end

  private

  def capture(name)
    assert_operator page.evaluate_script("document.documentElement.scrollWidth"), :<=, 390
    if ENV["CRM_EVIDENCE_DIR"]
      metrics = page.driver.browser.execute_cdp("Page.getLayoutMetrics")
      size = metrics.fetch("cssContentSize")
      shot = page.driver.browser.execute_cdp("Page.captureScreenshot", captureBeyondViewport: true,
        clip: { x: 0, y: 0, width: size["width"], height: size["height"], scale: 1 })
      File.binwrite(File.join(ENV["CRM_EVIDENCE_DIR"], "#{name}.png"), Base64.decode64(shot.fetch("data")))
    end
  end
end
