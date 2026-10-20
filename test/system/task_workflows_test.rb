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
      visit polymorphic_path(subject, template: template.id, task: task.id)
      assert_field "Message", with: "Hi Maya Sherpa, welcome back."
      if model == Organization
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
      else
        # Leads and clients prefill the composer instead of the suggested card.
        assert_no_selector "#suggested-message-heading"
      end
      assert_not task.reload.done?
      assert_operator page.evaluate_script("document.documentElement.scrollWidth"), :<=, 390
      capture("nudge-#{model.name.downcase}")
      other = model.create!(name: "Other")
      visit polymorphic_path(other, template: template.id, task: task.id)
      assert_no_selector "#suggested-message-heading"
      assert_no_field "Message", with: "Hi Maya Sherpa, welcome back."
      task.complete!
    end
  end

  test "converted lead proposals transfer to the client and survive template deletion" do
    client = Client.create!(name: "Maya Sherpa", email: "maya@example.com")
    lead = Lead.create!(name: "Maya", email: client.email, perfectbook_contact_id: 991)
    template = Template.create!(name: "Review invitation", subject: "Welcome back", body: "How was your trip?", purpose: :review_ask)
    old = lead.tasks.create!(title: "Existing follow-up", due_on: Date.current, template: template)
    visit lead_path(lead)
    accept_confirm { click_button "Convert to client" }
    assert_current_path client_path(client)
    assert_equal client, old.reload.subject
    PerfectBook::Booking.create!(perfectbook_id: 991, perfectbook_contact_id: 991,
      end_date: Date.current - 4, trip_name: "Everest", synced_at: Time.current)
    Tasks::GenerateAutomaticJob.perform_now
    task = Task.find_by!(idempotency_key: "review-ask:991")
    assert_equal client, task.subject
    visit templates_path
    within("li", text: "Review invitation") { click_button "Archive" }
    # Wait for the archive redirect before starting another Turbo navigation.
    assert_text "Template archived."
    assert_no_selector "li", text: "Review invitation"
    click_link "Archived", exact: false
    assert_current_path templates_path(tab: "archived")
    within("li", text: "Review invitation") { accept_confirm { click_button "Delete" } }
    assert_no_text "Review invitation"
    assert_nil task.reload.template_id
    assert_nil old.reload.template_id
    capture("converted-client-proposal")
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
