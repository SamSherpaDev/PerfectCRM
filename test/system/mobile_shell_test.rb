require "application_system_test_case"
require_relative "../support/google_sign_in_test_helper"

# The captain works from his phone: every rail page must fit a 390px
# viewport with no sideways scrolling, and the drawer must open the rail.
class MobileShellTest < ApplicationSystemTestCase
  include GoogleSignInTestHelper

  test "rail shell fits a 390px phone with a working drawer" do
    OmniAuth.config.mock_auth[:google_oauth2] = OmniAuth::AuthHash.new(
      provider: "google_oauth2", uid: "google-captain",
      extra: { id_token: JWT.encode(@claims, @key, "RS256") }
    )
    Google::Auth::IDTokens.stub(:oidc_key_source, @source) do
      visit "/auth/google_oauth2/callback"
      assert_selector "h1", text: "Today"
    end
    page.current_window.resize_to(390, 844)
    click_button "Open menu"
    assert_selector "nav[aria-label=Primary] a", text: "Inbox"
    assert_selector "nav[aria-label=Primary] a", text: "Leads"
    assert_selector "nav[aria-label=Primary] a", text: "Settings"
    click_button "Close menu"
    [ "/", "/inbox", "/leads", "/clients", "/pipeline", "/quotes", "/templates", "/design", "/settings/edit" ].each do |path|
      visit path
      width = page.evaluate_script("document.documentElement.scrollWidth")
      assert_operator width, :<=, 390, "#{path} overflows a 390px viewport (#{width}px)"
    end
  end
end
