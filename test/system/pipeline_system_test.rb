require "application_system_test_case"
require_relative "../../db/migrate/20260914211513_backfill_lead_stage_changed_at"
require_relative "../support/google_sign_in_test_helper"

# The pipeline board on desktop and the stage list on the phone: move a
# card through the Move menu (the keyboard path), require a reason on
# every loss, and keep one-handed use at 390px.
class PipelineSystemTest < ApplicationSystemTestCase
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

  test "keyboard move advances a card and lost needs a reason" do
    page.current_window.resize_to(1400, 900)
    Lead.create!(name: "Board Tashi", source: "website_form", status: "new",
      trip_interest: "Annapurna", expected_value_minor: 180_000)

    visit pipeline_path
    assert_selector "h1", text: "Pipeline"
    assert_selector "article.kcard", text: "Board Tashi"

    # Keyboard path: the Move menu lists every other stage.
    within "article.kcard", text: "Board Tashi" do
      find("summary", text: "Move").click
      click_link "Chatting"
    end
    assert_text "Moved to Chatting"
    assert_equal "chatting", Lead.find_by(name: "Board Tashi").status

    # Losing without a reason is refused; the sheet opens instead.
    within "article.kcard", text: "Board Tashi" do
      find("summary", text: "Move").click
      click_link "Lost"
    end
    assert_selector "dialog#lost-sheet[open]"
    within "#lost-sheet" do
      select "Price", from: "Reason"
      fill_in "Note (optional)", with: "Chose a cheaper operator"
      click_button "Mark lost"
    end
    assert_text "Moved to Lost"
    lost = Lead.find_by(name: "Board Tashi")
    assert_equal "lost", lost.status
    assert_equal "price", lost.lost_reason
  end

  test "stage list carries the phone at 390px" do
    Lead.create!(name: "Phone Pasang", source: "google_ads", status: "new",
      expected_value_minor: 320_000)
    page.current_window.resize_to(390, 844)

    visit pipeline_path
    assert_selector "h1", text: "Pipeline"
    assert_selector "section[aria-label='Stages']"
    assert_selector "summary", text: /New/
    assert_selector ".stage-count", text: "1"

    # The board grid stays hidden; the page never scrolls sideways.
    assert_no_selector ".board article.kcard"
    assert_no_overflow("pipeline at 390px")

    # Tapping the stage reveals its cards with the Move menu intact.
    # New opens by default when it holds cards; close and reopen it.
    assert_selector "article.kcard", text: "Phone Pasang"
    find("summary", text: /New/).click
    assert_no_selector "article.kcard", text: "Phone Pasang"
    find("summary", text: /New/).click
    assert_selector "article.kcard", text: "Phone Pasang"
    within "article.kcard", text: "Phone Pasang" do
      find("summary", text: "Move").click
      assert_selector "a", text: "Quoted"
    end
    assert_no_overflow("pipeline stage open at 390px")
  end

  test "dragging between columns keeps one ghost and clears it on cancel and drop" do
    Lead.create!(name: "Dragged traveler")
    page.current_window.resize_to(1400, 900)
    visit pipeline_path
    assert_selector "article.kcard", text: "Dragged traveler"
    page.execute_script <<~JS
      const card = document.querySelector('.board [data-pipeline-target="card"]')
      const columns = document.querySelectorAll('.board [data-pipeline-target="column"]')
      card.dispatchEvent(new DragEvent('dragstart', { bubbles: true, dataTransfer: new DataTransfer() }))
      columns[1].dispatchEvent(new DragEvent('dragover', { bubbles: true, cancelable: true }))
      columns[2].dispatchEvent(new DragEvent('dragover', { bubbles: true, cancelable: true }))
    JS
    assert_selector ".kcard-ghost", count: 1
    assert_selector '[data-stage="quoted"] .kcard-ghost', count: 1
    page.execute_script "document.querySelector('.board [data-pipeline-target=card]').dispatchEvent(new DragEvent('dragend', { bubbles: true }))"
    assert_no_selector ".kcard-ghost"
    page.execute_script <<~JS
      const card = document.querySelector('.board [data-pipeline-target="card"]')
      const column = document.querySelector('.board [data-pipeline-target="column"]')
      card.dispatchEvent(new DragEvent('dragstart', { bubbles: true, dataTransfer: new DataTransfer() }))
      column.dispatchEvent(new DragEvent('dragover', { bubbles: true, cancelable: true }))
      column.dispatchEvent(new DragEvent('drop', { bubbles: true, cancelable: true }))
    JS
    assert_no_selector ".kcard-ghost"
  end

  test "suggested message copy button copies the rendered follow-up" do
    template = Template.create!(name: "Follow-up", purpose: "itinerary_follow_up",
      subject: "Your {{trip}}", body: "Hi {{first_name}}")
    lead = Lead.create!(name: "Tashi Sherpa", trip_interest: "Annapurna")
    visit lead_path(lead, template: template.id, nudge: 1)
    assert_selector "h2", text: "Timeline"
    assert_no_selector "h2", text: "Suggested message"
    find(".composer .reply-details > summary").click
    assert_field "Subject", with: "Your Annapurna"
    assert_field "Message", with: "Hi Tashi"
  end

  test "phone move menu reaches Lost and Won for a single card" do
    lead = Lead.create!(name: "Phone move traveler")
    page.current_window.resize_to(390, 844)
    visit pipeline_path
    within "section[aria-label='Stages']" do
      find("summary", text: "Move", exact_text: true).click
      click_link "Lost", exact: true
    end
    assert_selector "dialog[open]"
    visit pipeline_path
    within "section[aria-label='Stages']" do
      find("summary", text: "Move", exact_text: true).click
      click_link "Won", exact: true
    end
    assert_current_path lead_path(lead)
  end

  test "missing lost reason preserves the submitted form" do
    lead = Lead.create!(name: "Original traveler")
    visit edit_lead_path(lead)
    fill_in "lead_name", with: "Edited traveler"
    select "Lost", from: "Status"
    click_button "Save changes"
    assert_field "lead_name", with: "Edited traveler"
    assert_selector "select option:checked", text: "Lost"
    assert_equal "Original traveler", lead.reload.name
    assert_equal "new", lead.status
    assert_not lead.activity_events.exists?(kind: "stage_change")
  end

  test "dragging preserves every active pipeline filter" do
    referrer = Organization.create!(name: "Alpine referrals")
    lead = Lead.create!(name: "Filtered traveler", source: "referral", trip_interest: "Annapurna",
      referred_by_organization: referrer)
    Lead.create!(name: "Unrelated traveler")
    page.current_window.resize_to(1400, 900)
    visit pipeline_path(source: "referral", trip: "Annapurna", advisor: referrer.id)
    assert_selector "article.kcard", text: lead.name
    page.execute_script <<~JS
      const card = document.querySelector('.board [data-pipeline-target="card"]')
      const destination = document.querySelector('.board [data-stage="chatting"]')
      card.dispatchEvent(new DragEvent('dragstart', { bubbles: true, dataTransfer: new DataTransfer() }))
      destination.dispatchEvent(new DragEvent('dragover', { bubbles: true, cancelable: true }))
      destination.dispatchEvent(new DragEvent('drop', { bubbles: true, cancelable: true }))
    JS
    assert_text "Moved to Chatting."
    assert_equal "chatting", lead.reload.status
    assert_field "Source", with: "referral"
    assert_field "Trip", with: "Annapurna"
    assert_field "Referred by", with: referrer.id.to_s
    assert_no_selector "article.kcard", text: "Unrelated traveler"
  end

  test "source picker filters client-only sources" do
    Client.create!(name: "Returning traveler", source: "repeat")
    Client.create!(name: "Website traveler", source: "website")
    Lead.create!(name: "Manual inquiry", source: "manual")
    page.current_window.resize_to(1400, 900)
    visit pipeline_path
    select "Repeat", from: "Source"
    click_button "Filter"
    assert_selector "article.kcard", text: "Returning traveler"
    assert_no_selector "article.kcard", text: "Website traveler"
    assert_no_selector "article.kcard", text: "Manual inquiry"
    select "Website", from: "Source"
    click_button "Filter"
    assert_selector "article.kcard", text: "Website traveler"
    assert_no_selector "article.kcard", text: "Returning traveler"
  end

  test "editing a migrated lead preserves its time in stage" do
    lead = Lead.create!(name: "Older inquiry")
    previous_update = 8.days.ago.change(usec: 0)
    lead.update_columns(stage_changed_at: nil, updated_at: previous_update)
    tracked = Lead.create!(name: "Tracked inquiry", stage_changed_at: 3.days.ago.change(usec: 0))
    tracked_stage_time = tracked.stage_changed_at
    BackfillLeadStageChangedAt.new.migrate(:up)
    assert_equal previous_update, lead.reload.stage_changed_at
    assert_equal previous_update, lead.updated_at
    assert_equal tracked_stage_time, tracked.reload.stage_changed_at
    page.current_window.resize_to(1400, 900)
    visit pipeline_path
    within "article.kcard", text: lead.name do
      assert_text "8d in stage"
    end
    visit edit_lead_path(lead)
    fill_in "lead_name", with: "Renamed inquiry"
    click_button "Save changes"
    assert_text "Lead saved."
    visit pipeline_path
    within "article.kcard", text: "Renamed inquiry" do
      assert_text "8d in stage"
      find("summary", text: "Move").click
      click_link "Chatting"
    end
    assert_text "Moved to Chatting."
    within "article.kcard", text: "Renamed inquiry" do
      assert_text "New in stage"
    end
  end

  test "report displays separate booking currencies and phone stages" do
    Lead.create!(name: "Everest inquiry", trip_interest: "Everest", source: "referral", expected_value_minor: 250_000)
    client = Client.create!(name: "Booked traveler", perfectbook_contact_id: 903)
    { "NPR" => 14_000_000, "USD" => 250_000 }.each_with_index do |(currency, total), index|
      PerfectBook::Booking.create!(perfectbook_id: 900 + index, perfectbook_contact_id: 903,
        currency: currency, total_minor: total, synced_at: Time.current, trip_name: "Everest")
    end
    page.current_window.resize_to(1400, 900)
    visit pipeline_path
    assert_selector ".col-sum", text: "NPR 140,000.00 · $2,500.00"
    assert page.evaluate_script(<<~JS), "Won currency totals must fit inside their column"
      (() => {
        const column = document.querySelector('.board [data-stage="won"]')
        const bounds = column.getBoundingClientRect()
        const range = document.createRange()
        range.selectNodeContents(column.querySelector('.col-sum'))
        return Array.from(range.getClientRects()).every(rect =>
          rect.left >= bounds.left && rect.right <= bounds.right)
      })()
    JS
    assert_text "Available once mail is connected"
    assert_text "Asks by source this month"
    capture_pipeline("desktop-board", ".board")
    find("#numbers-heading").scroll_to(:top)
    capture_pipeline("report-currencies", "#numbers-heading")
    page.current_window.resize_to(390, 844)
    visit pipeline_path
    within "section[aria-label='Stages']" do
      find("summary", text: "Move", exact_text: true).click
      assert_selector "a", text: "Lost", exact_text: true
      assert_selector "a", text: "Won", exact_text: true
    end
    assert_no_overflow("phone with full move menu")
    capture_pipeline("phone-move-menu", "section[aria-label=Stages] article")
  end

  test "stale nudge opens a rendered email and copies to the real clipboard" do
    Template.create!(name: "Follow-up", purpose: "itinerary_follow_up",
      subject: "Your {{trip}}", body: "Hi {{first_name}}, checking in about {{trip}}.")
    lead = Lead.create!(name: "Tashi Sherpa", email: "tashi@example.com", trip_interest: "Annapurna")
    lead.update_columns(last_touch_at: 9.days.ago)
    page.current_window.resize_to(1400, 900)
    visit pipeline_path
    within "article.kcard-stale", text: lead.name do
      find("summary", text: "Move").click
      click_link "Chatting", exact: true
    end
    assert_text "Moved to Chatting"
    within "article.kcard-stale", text: lead.name do
      click_link "Nudge"
    end
    find(".composer .reply-details > summary").click
    assert_field "Subject", with: "Your Annapurna"
    assert_field "Message", with: "Hi Tashi, checking in about Annapurna."
    assert lead.reload.stale?
    capture_pipeline("suggested-message")
    choose "Note", allow_label_click: true
    fill_in "Add a note", with: "Traveler replied about dates"
    click_button "Save note"
    visit pipeline_path
    assert_no_selector "article.kcard-stale", text: lead.name
  end

  test "conversion review joins the named client and allows only client stages" do
    client = Client.create!(name: "Existing traveler", email: "return@example.com")
    lead = Lead.create!(name: "Returning inquiry", email: client.email, source: "referral", expected_value_minor: 120_000)
    page.current_window.resize_to(1400, 900)
    visit pipeline_path
    within "article.kcard", text: lead.name do
      find("summary", text: "Move").click
      click_link "Won", exact: true
    end
    assert_current_path lead_path(lead)
    accept_confirm(/Existing traveler/) { click_button "Convert to client" }
    assert_current_path client_path(client)
    assert_equal client.id, lead.reload.converted_client_id
    visit pipeline_path
    assert_no_selector "article.kcard", text: lead.name
    within "article.kcard", text: client.name do
      find("summary", text: "Move").click
      assert_no_selector "a", text: "New", exact_text: true
      click_link "Post-trip", exact: true
    end
    assert_text "Moved to Post-trip"
    assert_equal "post_trip", client.reload.pipeline_stage
    assert_text "1 of 1 converted this year"
    capture_pipeline("converted-post-trip", ".board")
  end

  test "forged moves preserve conversion boundaries and exports retain pipeline data" do
    client = Client.create!(name: "Existing client", email: "guard@example.com")
    lead = Lead.create!(name: "Guarded lead", email: client.email, trip_interest: "Everest",
      expected_value_minor: 123_00)
    visit lead_path(lead)
    browser_request(convert_lead_path(lead), "POST", { expected_client_id: "new" })
    assert_not lead.reload.converted?
    browser_request(convert_lead_path(lead), "POST", { expected_client_id: client.id })
    assert_equal client.id, lead.reload.converted_client_id
    browser_request(pipeline_move_path, "PATCH", { client_id: client.id, to: "chatting" })
    assert_equal "won", client.reload.pipeline_stage
    browser_request(pipeline_move_path, "PATCH", { lead_id: lead.id, to: "new" })
    assert lead.reload.converted?
    lost = Lead.create!(name: "Exported loss", status: "lost", lost_reason: "dates", lost_note: "Next year",
      trip_interest: "Everest", expected_value_minor: 123_00)
    encoded = page.evaluate_async_script(<<~JS, settings_export_path)
      const done = arguments[arguments.length - 1];
      fetch(arguments[0]).then(r => r.arrayBuffer()).then(buffer => {
        done(btoa(Array.from(new Uint8Array(buffer), byte => String.fromCharCode(byte)).join('')))
      });
    JS
    files = {}
    Zip::InputStream.open(StringIO.new(Base64.decode64(encoded))) do |zip|
      while (entry = zip.get_next_entry)
        files[entry.name] = CSV.parse(zip.read.force_encoding(Encoding::UTF_8).delete_prefix("\uFEFF"), headers: true)
      end
    end
    row = files.fetch("leads.csv").find { |entry| entry["id"] == lost.id.to_s }
    assert_equal [ "Everest", "12300", "dates", "Next year" ],
      row.values_at("trip_interest", "expected_value_minor", "lost_reason", "lost_note")
    assert_equal "won", files.fetch("clients.csv").first["pipeline_stage"]
    visit edit_settings_path
    uncheck "setting_pipeline_digest"
    find("#setting_pipeline_digest").ancestor("form").click_button "Save", exact: true
    assert_text "Settings saved."
    assert_not Setting.current.reload.pipeline_digest
    visit edit_settings_path
    check "setting_pipeline_digest"
    find("#setting_pipeline_digest").ancestor("form").click_button "Save", exact: true
    assert_text "Settings saved."
    assert Setting.current.reload.pipeline_digest
  end

  test "trip filter matches mirrored bookings and converted lead interests" do
    lead = Lead.create!(name: "Annapurna traveler", trip_interest: "Annapurna",
      expected_value_minor: 250_000, perfectbook_contact_id: 901)
    client = lead.convert_to_client!
    Client.create!(name: "Unrelated traveler")
    PerfectBook::Booking.create!(perfectbook_id: 801, perfectbook_contact_id: 901,
      synced_at: Time.current, total_minor: 300_000, trip_name: "Everest")
    page.current_window.resize_to(1400, 900)
    visit pipeline_path
    %w[Everest Annapurna].each do |trip|
      select trip, from: "Trip"
      click_button "Filter"
      assert_selector "article.kcard", text: client.name
      assert_no_selector "article.kcard", text: "Unrelated traveler"
      assert_selector ".col-sum", text: "$3,000.00"
    end
  end

  test "incoming email clears a stale pipeline card" do
    lead = Lead.create!(name: "Active email traveler", email: "active@example.com")
    lead.update_columns(last_touch_at: 8.days.ago)
    page.current_window.resize_to(1400, 900)
    visit pipeline_path
    assert_selector "article.kcard-stale", text: lead.name
    parsed = Mail::Ingester.parse_raw("From: active@example.com\r\nTo: info@sherpaholidays.com\r\nSubject: Trip dates\r\nDate: #{Time.current.rfc2822}\r\n\r\nHere are my dates.")
    result = Mail::Ingester.ingest(parsed: parsed, provider: { thread_id: "active-thread", message_id: "active-message" })
    assert_equal :stored, result[:status]
    visit pipeline_path
    assert_selector "article.kcard", text: lead.name
    assert_no_selector "article.kcard-stale", text: lead.name
    assert_not lead.reload.stale?
    assert_match "0 stale", Pipeline::Report.new.digest_line
  end

  private

  def browser_request(path, method, params)
    page.evaluate_async_script(<<~JS, path, method, params)
      const done = arguments[arguments.length - 1];
      fetch(arguments[0], {method: arguments[1], headers: {
        'Content-Type': 'application/x-www-form-urlencoded',
        'X-CSRF-Token': document.querySelector('meta[name=csrf-token]')?.content || ''
      }, body: new URLSearchParams(arguments[2])}).then(r => r.text()).then(done);
    JS
  end

  def capture_pipeline(name, selector = "h1")
    return unless ENV["PIPELINE_EVIDENCE_DIR"].present?

    page.execute_script("document.querySelector(arguments[0]).scrollIntoView({behavior: 'instant', block: 'center'})", selector)
    page.evaluate_async_script("requestAnimationFrame(() => requestAnimationFrame(arguments[0]))")
    page.save_screenshot(File.join(ENV.fetch("PIPELINE_EVIDENCE_DIR"), "#{name}.png"))
  end

  def assert_no_overflow(context)
    width = page.evaluate_script("document.documentElement.scrollWidth")
    assert_operator width, :<=, 390, "#{context} overflows a 390px viewport (#{width}px)"
  end
end
