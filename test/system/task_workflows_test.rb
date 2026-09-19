require "application_system_test_case"
require_relative "../support/google_sign_in_test_helper"

class TaskWorkflowsTest < ApplicationSystemTestCase
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

  test "nudges render and copy approval drafts for every subject and reject another record's task" do
    template = Template.create!(name: "Welcome", subject: "Hello {{first_name}}", body: "Hi {{full_name}}, welcome back.", purpose: :review_ask)
    [ Client, Lead, Organization ].each do |model|
      subject = model.create!(name: "Maya Sherpa", email: "#{model.name.downcase}@example.com")
      task = subject.tasks.create!(title: "Nudge #{model.name}", due_on: Date.current, template: template)
      visit root_path
      within("li", text: task.title) { click_link "Nudge", exact: true }
      assert_current_path polymorphic_path(subject, template: template.id, task: task.id)
      assert_field "Message", with: "Hi Maya Sherpa, welcome back."
      page.driver.browser.execute_cdp("Browser.grantPermissions", origin: URI.join(page.current_url, "/").to_s, permissions: [ "clipboardReadWrite", "clipboardSanitizedWrite" ])
      within("section[aria-labelledby='suggested-message-heading']") do
        link = find_link("Open email draft")[:href]
        address, query = link.delete_prefix("mailto:").split("?", 2)
        assert_equal subject.email, address
        assert_equal "Hello Maya", URI.decode_www_form(query).to_h["subject"]
        assert_equal "Hi Maya Sherpa, welcome back.", URI.decode_www_form(query).to_h["body"]
        click_button "Copy message"
        assert_text "Message copied."
      end
      assert_equal "Hi Maya Sherpa, welcome back.", page.evaluate_async_script("const done = arguments[0]; navigator.clipboard.readText().then(done)")
      assert_not task.reload.done?
      assert_operator page.evaluate_script("document.documentElement.scrollWidth"), :<=, 390
      capture("nudge-#{model.name.downcase}")
      other = model.create!(name: "Other")
      visit polymorphic_path(other, template: template.id, task: task.id)
      assert_no_selector "#suggested-message-heading"
      task.complete!
    end
  end

  test "client follow-ups can be added snoozed and completed from Today" do
    client = Client.create!(name: "Maya Sherpa", email: "maya@example.com")
    visit client_path(client)
    fill_in "New follow-up", with: "Confirm Maya's itinerary"
    click_button "Add", exact: true
    assert_text "Follow-up saved."
    task = client.tasks.find_by!(title: "Confirm Maya's itinerary")
    visit root_path
    assert_text task.title
    capture("today-phone")
    within("li", text: task.title) do
      find("summary", text: "Snooze").click
      click_button "Tomorrow"
    end
    assert_text "Snoozed."
    assert_no_text task.title
    assert_equal Date.current + 1, task.reload.snoozed_until
    travel 1.day do
      @claims["exp"] = 1.hour.from_now.to_i
      OmniAuth.config.mock_auth[:google_oauth2].extra.id_token = JWT.encode(@claims, @key, "RS256")
      Google::Auth::IDTokens.stub(:oidc_key_source, @source) do
        visit "/auth/google_oauth2/callback"
        assert_selector "h1", text: "Today"
      end
      visit root_path
      assert_text task.title
      find("button[aria-label=\"Mark done: #{task.title}\"]").click
      assert_text "Done. Nice."
      assert_no_text task.title
      assert task.reload.done?
      visit client_path(client)
      assert_text "Completed: #{task.title}"
      capture("completed-follow-up")
    end
  end

  test "converted lead proposals appear on the client and survive template deletion" do
    client = Client.create!(name: "Maya Sherpa", email: "maya@example.com")
    lead = Lead.create!(name: "Maya", email: client.email, perfectbook_contact_id: 991)
    template = Template.create!(name: "Review invitation", subject: "Welcome back", body: "How was your trip?", purpose: :review_ask)
    old = lead.tasks.create!(title: "Existing follow-up", due_on: Date.current, template: template)
    visit lead_path(lead)
    accept_confirm { click_button "Convert to client" }
    assert_current_path client_path(client)
    assert_text old.title
    assert_equal client, old.reload.subject
    PerfectBook::Booking.create!(perfectbook_id: 991, perfectbook_contact_id: 991,
      end_date: Date.current - 4, trip_name: "Everest", synced_at: Time.current)
    Tasks::GenerateAutomaticJob.perform_now
    task = Task.find_by!(idempotency_key: "review-ask:991")
    assert_equal client, task.subject
    visit client_path(client)
    assert_text task.title
    find("button[aria-label='Mark done: Existing follow-up']").click
    assert_text "Done. Nice."
    assert client.activity_events.exists?(summary: "Completed: Existing follow-up")
    visit templates_path
    within("li", text: "Review invitation") { click_button "Archive" }
    click_link "Archived", exact: false
    within("li", text: "Review invitation") { accept_confirm { click_button "Delete" } }
    assert_no_text "Review invitation"
    assert_nil task.reload.template_id
    assert_nil old.reload.template_id
    visit root_path
    assert_text task.title
    capture("converted-client-proposal")
  end

  test "automatic jobs show overdue review repeat and deposit proposals only once without sending" do
    client = Client.create!(name: "Maya", perfectbook_contact_id: 992)
    PerfectBook::Booking.create!(perfectbook_id: 992, perfectbook_contact_id: 992,
      end_date: Date.current - 11.months, trip_name: "Annapurna", synced_at: Time.current)
    booking = PerfectBook::Booking.create!(perfectbook_id: 993, perfectbook_contact_id: 992,
      start_date: Date.current + 10, trip_name: "Everest", invoice_badge: "overdue",
      invoice_number: "SH-993", balance_due_minor: 5000, synced_at: Time.current)
    booking.update_columns(created_at: 6.days.ago)
    PerfectBook::Booking.create!(perfectbook_id: 994, perfectbook_contact_id: 992,
      end_date: Date.current - 1, trip_name: "Langtang", synced_at: Time.current)
    before_mail = ActionMailer::Base.deliveries.count
    Tasks::GenerateAutomaticJob.perform_now
    assert_equal 3, client.tasks.count
    Tasks::GenerateAutomaticJob.perform_now
    assert_equal 3, client.tasks.count
    assert_equal before_mail, ActionMailer::Base.deliveries.count
    visit root_path
    client.tasks.each { |task| assert_text task.title }
    assert_text "Everest"
    within("section[aria-labelledby='returned-heading']") { click_button "Create review ask" }
    assert_text "Review ask saved."
    assert_text "Ask Maya for a review (Langtang)"
    assert_equal 4, client.tasks.count
    capture("automatic-proposals")
  end

  test "captain can disable and reenable the morning digest" do
    visit edit_settings_path
    within("section[aria-labelledby='digest-heading']") do
      uncheck "Send the morning digest"
      click_button "Save"
    end
    assert_text "Settings saved."
    assert_no_checked_field "Send the morning digest"
    assert_not Setting.current.reload.digest_enabled?
    visit edit_settings_path
    within("section[aria-labelledby='digest-heading']") do
      check "Send the morning digest"
      click_button "Save"
    end
    assert_text "Settings saved."
    assert_checked_field "Send the morning digest"
    assert Setting.current.reload.digest_enabled?
    capture("digest-settings")
    if ENV["TASK_EVIDENCE_DIR"].present?
      File.write(File.join(ENV.fetch("TASK_EVIDENCE_DIR"), "digest.eml"), CaptainDigestMailer.morning.message.to_s)
    end
  end

  private

  def capture(name)
    return unless ENV["TASK_EVIDENCE_DIR"].present?

    page.evaluate_async_script("const done = arguments[0]; Promise.all(document.getAnimations().map(a => a.finished.catch(() => {}))).then(done)")
    size = page.driver.browser.execute_cdp("Page.getLayoutMetrics").fetch("cssContentSize")
    shot = page.driver.browser.execute_cdp("Page.captureScreenshot", captureBeyondViewport: true, clip: size.merge("scale" => 1))
    File.binwrite(File.join(ENV.fetch("TASK_EVIDENCE_DIR"), "#{name}.png"), Base64.decode64(shot.fetch("data")))
  end
end
