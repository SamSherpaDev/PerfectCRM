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

  test "website inquiry budget bands are readable on a phone" do
    lead = Lead.create!(name: "Website inquiry", budget_band: "4000_7000")
    {
      "4000_7000" => "4,000-7,000 per person",
      "under_2000" => "Under 2,000 per person",
      "2000_4000" => "2,000-4,000 per person",
      "7000_plus" => "7,000+ per person",
      "discuss" => "To discuss"
    }.each do |band, label|
      lead.update!(budget_band: band)
      visit lead_path(lead)
      click_button "Details", exact: true
      within "section[aria-labelledby='details-heading']" do
        assert_selector "dd", exact_text: label
      end
      capture("inquiry-budget-#{band}-phone")
    end
  end

  test "captain configures automations and rotates credentials on a phone" do
    visit edit_settings_path
    fill_in "n8n webhook URL", with: "https://n8n.example.com/webhook/leads"
    click_button "Save automations"
    assert_text "Automations saved."
    assert_field "n8n webhook URL", with: "https://n8n.example.com/webhook/leads"
    old_key = Setting.current.site_key
    within "section[aria-labelledby='automations-heading']" do
      accept_confirm { all("button", text: "Rotate").first.click }
    end
    assert_no_text old_key
    assert_text Setting.current.site_key
    within "section[aria-labelledby='automations-heading']" do
      accept_confirm { all("button", text: "Rotate").last.click }
    end
    assert_text "New secret (shown once)"
    secret = Setting.current.relay_secret
    assert_text secret
    capture("automation-rotation-phone")
    visit edit_settings_path
    assert_no_text secret
    assert_text Setting.current.masked_relay_secret
    fill_in "n8n webhook URL", with: ""
    click_button "Save automations"
    assert_text "Automations saved."
    assert_field "n8n webhook URL", with: ""
    assert_not Setting.current.webhooks_enabled?
    capture("automation-disabled-phone")
  end

  test "traveler emails can be reassigned and duplicates show errors for both owner types" do
    [ Client, Lead ].each do |model|
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
      click_button "Details", exact: true
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
    click_button "Details", exact: true
    assert_text "maya@example.com"
    capture("lead-phone")
    accept_confirm { click_button "Convert to client" }
    assert_text "Lead converted. Their timeline moved with them."
    click_button "Details", exact: true
    assert_text "Started as a lead"
    assert_text "Spring 2027"
    click_button "Thread"
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
    find("summary[aria-label='More actions']").click
    accept_confirm { click_button "Archive client" }
    assert_text "Client archived."
    click_link client.name
    assert_button "Restore"
    click_button "Restore"
    find("summary[aria-label='More actions']").click
    assert_button "Archive client"
  end

  test "older notes and activity are reachable on every record type" do
    [ Client, Lead ].each do |model|
      record = model.create!(name: "Long history")
      51.times { |i| record.notes.create!(body: "Historic note #{i}", created_at: i.minutes.ago) }
      51.times { |i| record.activity_events.create!(kind: "email", summary: "Historic email #{i}", occurred_at: i.days.ago) }
      visit polymorphic_path(record)
      click_link "Load older"
      assert_text "Historic note 50"
      capture("#{model.model_name.param_key}-older-history")
    end
    record = Organization.create!(name: "Long history")
    51.times { |i| record.notes.create!(body: "Historic note #{i}", created_at: i.minutes.ago) }
    51.times { |i| record.activity_events.create!(kind: "email", summary: "Historic email #{i}", occurred_at: i.days.ago) }
    visit polymorphic_path(record)
    click_link "Older notes"
    assert_text "Historic note 50"
    click_link "Older activity"
    assert_text "Historic email 50"
    capture("organization-older-history")
  end

  test "search sorting and export operate through the running application" do
    [ Client, Lead, Organization ].each do |model|
      model.create!(name: "Match Alpha")
      model.create!(name: "Match Zulu")
      visit(model == Lead ? leads_path : clients_path(tab: model == Organization ? "organizations" : "clients"))
      fill_in(model == Lead ? "Search leads" : "Search clients", with: "Match")
      click_button "Search"
      select "Name", from: "sort"
      assert_selector "select option[selected][value=name]"
      assert_equal [ "Match Alpha", "Match Zulu" ], all("main a").map(&:text).select { |text| text.start_with?("Match") }
    end
    client = Client.create!(name: "=SUM(1,2)", phone: "+123456", tag_list: "@tag")
    inquiry = Lead.create!(name: "Website traveler", message: "Spring adventure", trip_title: "Nepal",
      travel_month: 4, travel_year: 2027, timing_unknown: true, party_size: 2,
      budget_band: "4000_7000", metadata: { attribution: { gclid: "export-click" } })
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
    inquiry_row = tables["leads.csv"].find { |r| r["id"] == inquiry.id.to_s }
    assert_equal [ "Spring adventure", "Nepal", "4", "2027", "true", "2", "4000_7000", inquiry.reference ],
      inquiry_row.values_at("message", "trip_title", "travel_month", "travel_year", "timing_unknown", "party_size", "budget_band", "reference")
    assert_equal "export-click", JSON.parse(inquiry_row["metadata"]).dig("attribution", "gclid")
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
    assert_equal [ 200, 200 ], result
    assert_equal before + 1, Client.count
    assert lead.reload.converted?
    result = page.evaluate_async_script(<<~JS, lead_path(lead), lead_notes_path(lead))
      const leadPath = arguments[0], notePath = arguments[1], done = arguments[arguments.length - 1];
      const headers = {'Content-Type': 'application/x-www-form-urlencoded', 'X-CSRF-Token': document.querySelector('meta[name="csrf-token"]')?.content || ''};
      Promise.all([fetch(leadPath, {method: 'POST', headers, body: '_method=patch&lead[name]=Late+edit'}),
        fetch(notePath, {method: 'POST', headers, body: 'note[body]=Late+note'})])
        .then(responses => done(responses.map(r => r.status))).catch(e => done(String(e)));
    JS
    assert_equal [ 200, 200 ], result
    assert_equal "Concurrent inquiry", lead.reload.name
    assert_empty lead.notes
    assert_empty lead.converted_client.notes
    visit lead_path(lead)
    assert_no_button "Save note"
    capture("converted-lead-readonly-phone")
  end

  test "returning inquiries name the existing client and append history without creating clients" do
    client = Client.create!(name: "Returning traveler", email: "repeat@example.com", perfectbook_contact_id: 321, source: "referral", tag_list: "original")
    client.people.create!(name: "Maya", email: "maya@example.com")
    [ :email, :perfectbook_contact_id, :email ].each_with_index do |identity, index|
      visit new_lead_path
      fill_in "Display name", with: "Return inquiry #{index}"
      if identity == :email
        fill_in "Primary email", with: "REPEAT@example.com"
      else
        fill_in "PerfectBook contact id", with: "321"
      end
      select "Google ads", from: "Source"
      fill_in "Campaign", with: "Spring #{index}"
      fill_in "Tags", with: "everest"
      fill_in "lead[people_attributes][0][name]", with: "Maya"
      fill_in "lead[people_attributes][0][email]", with: "maya@example.com"
      click_button "Save lead"
      assert_selector "h1", text: "Return inquiry #{index}"
      lead = Lead.find_by!(name: "Return inquiry #{index}")
      click_button "Reply"
      choose "Note", allow_label_click: true
      fill_in "Add a note", with: "Return plans #{index}"
      click_button "Save note"
      assert_text "Return plans #{index}"
      before = Client.count
      accept_confirm "This is an existing client: Returning traveler. Convert will attach this lead's history to them." do
        click_button "Convert to client"
      end
      assert_selector "h1", text: "Returning traveler"
      assert_text "Returned as a lead from Google ads"
      event = client.activity_events.where(kind: "conversion").order(:id).last
      assert_equal "Spring #{index}", event.metadata["campaign"]
      assert_text "Return plans #{index}"
      assert_no_text "Started as a lead"
      assert_equal before, Client.count
      assert_equal client.id, lead.reload.converted_client_id
      assert_equal 1, client.people.count
      assert_equal %w[everest original], client.tags.reload.pluck(:name)
      assert_equal "referral", client.reload.source
      assert_equal index + 1, client.notes.count
      assert_equal index + 1, client.activity_events.where(kind: "note").count
      capture("returning-client-#{index}-phone")
      visit lead_path(lead)
      assert_no_button "Save note"
      assert_no_button "Convert to client"
    end
  end

  test "open leads can share an email when created and reopened" do
    active = Lead.create!(name: "Active inquiry", email: "open@example.com")
    visit new_lead_path
    fill_in "Display name", with: "Next inquiry"
    fill_in "Primary email", with: active.email
    click_button "Save lead"
    assert_selector "h1", text: "Next inquiry"
    repeat = Lead.find_by!(name: "Next inquiry")
    assert_not_equal active.id, repeat.id
    assert_equal active.email, repeat.email

    visit edit_lead_path(repeat)
    select "Lost", from: "Status"
    select "Dates", from: "Lost reason"
    click_button "Save changes"
    assert_selector "h1", text: "Next inquiry"
    assert_equal "lost", repeat.reload.status

    visit edit_lead_path(repeat)
    select "Chatting", from: "Status"
    click_button "Save changes"
    assert_selector "h1", text: "Next inquiry"
    assert_equal "chatting", repeat.reload.status
    assert_equal active.email, repeat.email
  end

  test "only open leads reserve PerfectBook contacts and external references remain unique" do
    active = Lead.create!(name: "Active inquiry", perfectbook_contact_id: 765)
    visit new_lead_path
    fill_in "Display name", with: "Next inquiry"
    fill_in "PerfectBook contact id", with: "765"
    click_button "Save lead"
    assert_selector "[role=alert]", text: "has already been taken"
    select "Lost", from: "Status"
    select "Dates", from: "Lost reason"
    click_button "Save lead"
    assert_selector "h1", text: "Next inquiry"
    lost = Lead.order(:id).last
    visit edit_lead_path(lost)
    select "Chatting", from: "Status"
    click_button "Save changes"
    assert_selector "[role=alert]", text: "has already been taken"
    capture("lead-perfectbook_contact_id-open-guard")
    visit edit_lead_path(active)
    select "Lost", from: "Status"
    select "Dates", from: "Lost reason"
    click_button "Save changes"
    assert_selector "h1", text: "Active inquiry"
    visit edit_lead_path(lost)
    select "Chatting", from: "Status"
    click_button "Save changes"
    assert_selector "h1", text: "Next inquiry"
    assert_equal "chatting", lost.reload.status
    Lead.create!(name: "Historical import", status: "lost", lost_reason: "dates", external_ref: "import-123")
    visit new_lead_path
    fill_in "Display name", with: "Duplicate import"
    fill_in "External reference", with: "import-123"
    click_button "Save lead"
    assert_selector "[role=alert]", text: "External ref has already been taken"
    capture("lead-external-reference-guard")
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
