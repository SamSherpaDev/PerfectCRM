require "application_system_test_case"
require_relative "../support/google_sign_in_test_helper"

class BookingLinkSystemTest < ApplicationSystemTestCase
  include GoogleSignInTestHelper

  URL = "https://calendar.app.google/sherpa-call".freeze

  setup do
    OmniAuth.config.mock_auth[:google_oauth2] = OmniAuth::AuthHash.new(
      provider: "google_oauth2", uid: "google-captain",
      extra: { id_token: JWT.encode(@claims, @key, "RS256") }
    )
    Google::Auth::IDTokens.stub(:oidc_key_source, @source) do
      visit "/auth/google_oauth2/callback"
      assert_selector "h1", text: "Today"
    end
    page.current_window.resize_to(1400, 900)
  end

  test "the Call booking card saves the link and the missed-call text adds the booking line at desktop and phone width" do
    visit edit_settings_path
    within("section[aria-labelledby='booking-heading']") do
      assert_selector "h2", text: "Call booking"
      assert_text "Until it is set, the booking line is left out of texts and emails."
      fill_in "Booking page link", with: "http://calendar.app.google/sherpa-call"
      tolerate_submit_navigation { click_button "Save booking link" }
    end
    tolerate_navigation_assertion { assert_selector "[role=alert]", text: "Booking page link must be a full link starting with https://" }
    assert_equal "", Setting.current.reload.booking_url
    capture("settings-error-desktop")
    within("section[aria-labelledby='booking-heading']") do
      fill_in "Booking page link", with: URL
      tolerate_submit_navigation { click_button "Save booking link" }
    end
    tolerate_navigation_assertion { assert_text "Settings saved." }
    assert_equal URL, Setting.current.reload.booking_url
    find("#booking-heading").execute_script("this.scrollIntoView({block: 'center'})")
    capture("settings-desktop")

    lead = Lead.create!(name: "Booking System", email: "booking-sys@example.com", phone: "+14155550204", source: "website_form")
    text = "Hi Booking, this is Sam at SherpaHolidays. I just tried giving you a quick call about your trip inquiry. " \
      "When is a good time for us to connect by phone, or is text easier for you?\nYou can also pick a call time here: #{URL}"
    visit lead_path(lead)
    within(".calls") { tolerate_submit_navigation { click_button "No answer" } }
    tolerate_navigation_assertion { assert_text "Call logged: No answer. Send a short text by hand." }
    within("[data-missed-call-reminder]") do
      assert_equal text, find("textarea[aria-label='Text 1 to send by hand']").value
      assert_button "Copy text", count: 1
      assert_no_selector "form"
    end
    capture("text-1-desktop", ".calls")

    page.current_window.resize_to(390, 844)
    visit edit_settings_path
    find("#booking-heading").execute_script("this.scrollIntoView({block: 'center'})")
    assert_equal URL, find_field("Booking page link").value
    capture("settings-phone")
    assert_operator page.evaluate_script("document.documentElement.scrollWidth"), :<=, 390
    visit lead_path(lead, anchor: "record-details")
    within("[data-missed-call-reminder]") do
      assert_equal text, find("textarea[aria-label='Text 1 to send by hand']").value
    end
    capture("text-1-phone", ".calls")
    assert_operator page.evaluate_script("document.documentElement.scrollWidth"), :<=, 390
  end

  private

  def capture(name, selector = nil)
    return unless ENV["BOOKING_LINK_EVIDENCE"]

    find(selector).execute_script("this.scrollIntoView({block: 'center'})") if selector
    page.save_screenshot(File.join(ENV.fetch("BOOKING_LINK_EVIDENCE"), "#{name}.png"))
  end
end
