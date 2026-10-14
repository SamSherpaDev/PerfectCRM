require "application_system_test_case"
require_relative "../support/google_sign_in_test_helper"

class NotYetCalledSystemTest < ApplicationSystemTestCase
  include GoogleSignInTestHelper

  EVIDENCE = ENV["NOT_YET_CALLED_EVIDENCE"]

  test "captain sees untouched inquiries and clears one by logging a call" do
    travel_to Time.zone.local(2026, 10, 14, 12) do
      oldest = inquiry("Oldest inquiry", 6.days.ago)
      automatic = inquiry("Automatic greeting only", 5.days.ago)
      greeting = reply(automatic, "sent")
      AutomaticFirstReply.create!(lead: automatic, message: greeting, email: automatic.email)
      failed = inquiry("Failed reply only", 4.days.ago)
      %w[failed queued sending].each { |status| reply(failed, status) }
      fallback = inquiry("No email thread", nil)
      fallback.update_columns(created_at: 3.days.ago)
      reply(inquiry("Personal reply sent", 3.days.ago), "sent")
      reply(inquiry("Imported personal reply", 3.days.ago), "received")
      CallLog::OUTCOMES.each do |outcome|
        CallLog.record!(inquiry("Called #{outcome}", 3.days.ago), key: "check-#{outcome}",
          occurred_at: 2.days.ago, outcome: outcome, direction: "outbound")
      end
      inquiry("Already chatting", 3.days.ago).update!(status: "chatting")
      inquiry("Archived", 3.days.ago).archive!
      inquiry("Converted", 3.days.ago).convert_to_client!
      inquiry("Recent", 1.hour.ago)
      browser_sign_in
      expected = [ oldest.name, automatic.name, failed.name, fallback.name ]
      assert_equal expected, inquiry_links
      capture("today-desktop")
      page.current_window.resize_to(390, 844)
      assert_operator page.evaluate_script("document.documentElement.scrollWidth"), :<=, 390
      capture("today-phone")
      page.current_window.resize_to(1400, 900)
      click_link oldest.name
      find("summary", text: "Log a call").click
      click_button "Save call"
      assert_text "Call saved."
      visit root_path
      assert_equal expected.drop(1), inquiry_links
      capture("today-after-call")
      mail = CaptainDigestMailer.morning.deliver_now
      assert_includes mail.body.decoded, "Not yet called: 3."
      assert_includes mail.body.decoded, "http://example.com/"
      File.write(File.join(EVIDENCE, "daily-digest.txt"), mail.body.decoded) if EVIDENCE
    end
  end

  test "weekends and exact business day boundary do not prematurely flag inquiries" do
    travel_to Time.zone.local(2026, 10, 17, 12) do
      inquiry("Thursday overdue", Time.zone.local(2026, 10, 15, 23, 59, 59))
      inquiry("Friday boundary", Time.zone.local(2026, 10, 16, 12))
      inquiry("Friday afternoon", Time.zone.local(2026, 10, 16, 15))
      browser_sign_in
      assert_equal [ "Thursday overdue" ], inquiry_links
      travel 1.day
      browser_sign_in
      assert_equal [ "Thursday overdue" ], inquiry_links
      travel 1.day
      browser_sign_in
      assert_equal [ "Thursday overdue" ], inquiry_links
      travel 1.second
      visit root_path
      assert_equal [ "Thursday overdue", "Friday boundary" ], inquiry_links
      capture("business-day-boundary")
    end
  end

  private

  def inquiry(name, received_at)
    Lead.create!(name: name, email: "inquiry@example.test", received_at: received_at)
  end

  def reply(lead, status)
    lead.conversations.create!(subject: "Trip").messages.create!(direction: "out", status: status,
      subject: "Trip", to_addrs: lead.email, text_body: "Hello", sent_at: 1.hour.ago)
  end

  def browser_sign_in
    @claims["exp"] = 1.hour.from_now.to_i
    OmniAuth.config.mock_auth[:google_oauth2] = OmniAuth::AuthHash.new(
      provider: "google_oauth2", uid: "google-captain",
      extra: { id_token: JWT.encode(@claims, @key, "RS256") }
    )
    Google::Auth::IDTokens.stub(:verify_oidc, @claims) do
      visit "/auth/google_oauth2/callback"
      assert_selector "h1", text: "Today"
    end
    page.current_window.resize_to(1400, 900)
  end

  def inquiry_links
    within("section[aria-labelledby='not-yet-called-heading']") { all("a").map(&:text) }
  end

  def capture(name)
    find("section[aria-labelledby='not-yet-called-heading']").execute_script(
      "window.scrollTo(0, this.getBoundingClientRect().top + window.scrollY - 80)"
    )
    page.save_screenshot(File.join(EVIDENCE, "#{name}.png")) if EVIDENCE
  end
end
