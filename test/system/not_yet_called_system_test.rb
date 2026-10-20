require "application_system_test_case"
require_relative "../support/google_sign_in_test_helper"

class NotYetCalledSystemTest < ApplicationSystemTestCase
  include GoogleSignInTestHelper

  EVIDENCE = ENV["NOT_YET_CALLED_EVIDENCE"]

  # Chrome uses the real clock for cookie expiry, so travel to future weekdays.
  test "captain sees uncalled phone inquiries and due retries with attempt badges, and logs calls or schedules from Today" do
    travel_to [ Date.current, Today::Summary::CALL_CADENCE_STARTS_ON + 7 ].max.next_occurring(:wednesday).in_time_zone.change(hour: 12) do
      oldest = inquiry("Oldest uncalled", 2.days.ago)
      recent = inquiry("Recent uncalled", 45.minutes.ago)
      Lead.create!(name: "No phone inquiry", email: "nophone@example.test", received_at: 3.days.ago)

      second_try = inquiry("Second try voicemail", 2.days.ago)
      CallLog.record!(second_try, key: "sys-vm-1", occurred_at: 1.day.ago, outcome: "voicemail", direction: "outbound")

      third_try = inquiry("Third try no answer", 4.days.ago)
      CallLog.record!(third_try, key: "sys-na-1", occurred_at: 3.days.ago, outcome: "voicemail", direction: "outbound")
      CallLog.record!(third_try, key: "sys-na-2", occurred_at: 2.days.ago, outcome: "no_answer", direction: "outbound")

      connected = inquiry("Already connected", 3.days.ago)
      CallLog.record!(connected, key: "sys-conn-1", occurred_at: 2.days.ago, outcome: "connected", direction: "outbound")

      three_attempts = inquiry("Exhausted 3 tries", 5.days.ago)
      CallLog.record!(three_attempts, key: "sys-ex-1", occurred_at: 4.days.ago, outcome: "voicemail", direction: "outbound")
      CallLog.record!(three_attempts, key: "sys-ex-2", occurred_at: 3.days.ago, outcome: "no_answer", direction: "outbound")
      CallLog.record!(three_attempts, key: "sys-ex-3", occurred_at: 1.day.ago, outcome: "voicemail", direction: "outbound")

      inquiry("Not interested", 3.days.ago).mark_not_interested!
      inquiry("Archived", 3.days.ago).archive!
      inquiry("Converted", 3.days.ago).convert_to_client!

      browser_sign_in
      expected = [ recent.name, second_try.name, third_try.name, oldest.name ]
      assert_equal expected, inquiry_links

      within("#call_list_lead_#{oldest.id}") do
        assert_text "1st try"
        assert_text "Waiting 2 days"
      end
      within("#call_list_lead_#{second_try.id}") do
        assert_text "2nd try"
        assert_text "Last: Voicemail 1 day ago"
      end
      within("#call_list_lead_#{third_try.id}") do
        assert_text "3rd try"
        assert_text "Last: No answer 2 days ago"
      end

      within("#call_list_lead_#{oldest.id}") do
        talked = find_button("Talked").evaluate_script("JSON.stringify(this.getBoundingClientRect())")
        schedule = find("summary", text: "Schedule call").evaluate_script("JSON.stringify(this.getBoundingClientRect())")
        talked, schedule = [ talked, schedule ].map { |rect| JSON.parse(rect).values_at("top", "height") }
        assert_equal schedule, talked, "one-tap call buttons line up with Schedule call"
      end

      capture("today-desktop")
      page.current_window.resize_to(390, 844)
      assert_operator page.evaluate_script("document.documentElement.scrollWidth"), :<=, 390
      within("#call_list_lead_#{oldest.id}") do
        assert_operator find_button("Talked").native.size.height, :>=, 44
      end
      capture("today-phone")

      # Check Night theme on phone and desktop as well
      page.execute_script("document.documentElement.dataset.scheme = 'night'; document.body.dataset.scheme = 'night'")
      assert_operator page.evaluate_script("document.documentElement.scrollWidth"), :<=, 390
      capture("today-phone-night")
      page.current_window.resize_to(1400, 900)
      assert_operator page.evaluate_script("document.documentElement.scrollWidth"), :<=, 1400
      capture("today-desktop-night")
      page.execute_script("document.documentElement.dataset.scheme = 'paper'; document.body.dataset.scheme = 'paper'")

      # One-tap Voicemail right on Today logs attempt 1 and drops the lead until tomorrow (Day 1)
      tolerate_submit_navigation do
        within("#call_list_lead_#{oldest.id}") { click_button "Voicemail" }
      end
      tolerate_navigation_assertion do
        assert_text "Call logged: Voicemail."
        assert_no_selector "#call_list_lead_#{oldest.id}"
        assert_equal [ recent.name, second_try.name, third_try.name ], inquiry_links
      end

      # One-tap Talked on 2nd try connects and drops the lead permanently
      tolerate_submit_navigation do
        within("#call_list_lead_#{second_try.id}") { click_button "Talked" }
      end
      tolerate_navigation_assertion do
        assert_text "Call logged: Talked."
        assert_no_selector "#call_list_lead_#{second_try.id}"
        assert_equal [ recent.name, third_try.name ], inquiry_links
      end
      capture("today-after-call")

      mail = CaptainDigestMailer.morning.deliver_now
      assert_includes mail.body.decoded, "Calls to make today: 2."
      assert_includes mail.body.decoded, "http://example.com/"
      File.write(File.join(EVIDENCE, "daily-digest.txt"), mail.body.decoded) if EVIDENCE
    end
  end

  private

  def inquiry(name, received_at, phone: "+1 415 555 0134")
    Lead.create!(name: name, email: "inquiry@example.test", phone_raw: phone, received_at: received_at)
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
    page.evaluate_async_script("const done = arguments[0]; Promise.all(document.getAnimations().map(a => a.finished.catch(() => {}))).then(done)")
    find("section[aria-labelledby='not-yet-called-heading']").execute_script(
      "window.scrollTo(0, this.getBoundingClientRect().top + window.scrollY - 80)"
    )
    page.save_screenshot(File.join(EVIDENCE, "#{name}.png")) if EVIDENCE
  end
end
