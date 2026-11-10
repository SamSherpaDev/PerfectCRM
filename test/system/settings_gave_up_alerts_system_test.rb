require "application_system_test_case"
require_relative "../support/google_sign_in_test_helper"

# Public behavior: the captain opens Settings and the Automations card lists
# every lead alert the outbox gave up on, and nothing else as "Gave up".
# Oracle: the retry-cap contract (give up after 20 attempts or 24 hours), not
# the view. The rows reach gave-up through the real minute drain, so a card
# that lists the wrong rows, the wrong attempt count, or a broken lead link
# fails here.
class SettingsGaveUpAlertsSystemTest < ApplicationSystemTestCase
  include GoogleSignInTestHelper
  include ActiveJob::TestHelper

  test "captain sees both kinds of gave-up lead alerts on the Automations card at desktop and phone widths" do
    lead = nil
    travel_to Time.zone.local(2026, 11, 9, 14, 5) do
      lead = Lead.create!(name: "Anna Lindqvist", email: "anna@example.test", source: "website_form")
      # Attempt cap: 20 tries used up and the last claim has expired.
      lead.lead_notifications.create!(event: "lead.created", attempts: 20, available_at: 1.minute.ago)
      # Age cap: a day old with a single try.
      lead.lead_notifications.create!(event: "email_copy", attempts: 1, created_at: 25.hours.ago, available_at: 1.minute.ago)
      # Neither of these may show as gave up: one was delivered long ago,
      # one is still retrying with a job in flight.
      lead.lead_notifications.create!(event: "auto_first_reply", attempts: 1, created_at: 30.hours.ago, delivered_at: 29.hours.ago)
      lead.lead_notifications.create!(event: "lead.details_added", attempts: 2, last_enqueued_at: 1.minute.ago)

      assert_no_enqueued_jobs only: LeadNotificationJob do
        LeadNotification.enqueue_pending
      end
    end

    sign_in_browser
    [ 1400, 390 ].each do |width|
      page.current_window.resize_to(width, 900)
      visit edit_settings_path

      activity = find("h3", text: "Recent automation activity").find(:xpath, "..")
      within activity do
        assert_selector ".badge", text: "Gave up", count: 2
        within "li", text: "lead.created webhook" do
          assert_selector "p", exact_text: "lead.created webhook (lead.created) gave up after 20 attempts"
          assert_selector "p", text: "14:05"
          assert_link lead.reference, href: lead_path(lead)
          assert_selector ".badge", text: "Gave up", count: 1
        end
        within "li", text: "Inquiry email alert" do
          assert_selector "p", exact_text: "Inquiry email alert (email_copy) gave up after 1 attempt"
          assert_selector "p", text: "14:05"
          assert_link lead.reference, href: lead_path(lead)
          assert_selector ".badge", text: "Gave up", count: 1
        end
        # The row icon is a 16px square (h-4 w-4); long wording on a phone
        # must wrap beside it, not squeeze it.
        all("li svg", minimum: 2).each do |icon|
          assert_equal [ 16, 16 ], icon.rect.then { |rect| [ rect.width.round, rect.height.round ] }
        end
        assert_no_text "Automatic first reply"
        assert_no_text "lead.details_added"
      end
      assert_operator page.evaluate_script("document.documentElement.scrollWidth"), :<=, width
    end

    within find("h3", text: "Recent automation activity").find(:xpath, "..") do
      within("li", text: "Inquiry email alert") { click_link lead.reference }
    end
    assert_selector "h1", text: "Anna Lindqvist"
    assert_current_path lead_path(lead)
  end

  private

  def sign_in_browser
    OmniAuth.config.mock_auth[:google_oauth2] = OmniAuth::AuthHash.new(
      provider: "google_oauth2", uid: "google-captain",
      extra: { id_token: JWT.encode(@claims, @key, "RS256") }
    )
    Google::Auth::IDTokens.stub(:oidc_key_source, @source) do
      visit "/auth/google_oauth2/callback"
      assert_selector "h1", text: "Today"
    end
  end
end
