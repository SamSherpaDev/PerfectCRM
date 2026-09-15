require "application_system_test_case"
require_relative "../support/google_sign_in_test_helper"

class AppearanceTest < ApplicationSystemTestCase
  include GoogleSignInTestHelper

  test "appearance choice applies the moment it is clicked and sticks" do
    OmniAuth.config.mock_auth[:google_oauth2] = OmniAuth::AuthHash.new(
      provider: "google_oauth2", uid: "google-captain",
      extra: { id_token: JWT.encode(@claims, @key, "RS256") }
    )
    Google::Auth::IDTokens.stub(:oidc_key_source, @source) do
      visit "/auth/google_oauth2/callback"
      assert_selector "h1", text: "Today"
    end
    visit edit_settings_path
    assert_selector "html[data-scheme=paper]"
    page.execute_script("window.appearanceVisit = true")
    choose "Night", allow_label_click: true
    assert_selector "html[data-scheme=night]"
    assert_text "Settings saved"
    assert_equal "night", Setting.current.reload.appearance
    assert_equal "rgb(20, 17, 14)", page.evaluate_script("getComputedStyle(document.body).backgroundColor")
    visit edit_settings_path
    assert_selector "html[data-scheme=night]"
    page.execute_script("window.appearanceVisit = true")
    page.execute_script("Turbo.visit(arguments[0])", root_path)
    assert_selector "h1", text: "Today"
    assert_selector "html[data-scheme=night]"
    assert page.evaluate_script("window.appearanceVisit"), "Navigation must retain the Turbo document"
    page.execute_script("Turbo.visit(arguments[0])", edit_settings_path)
    assert_selector "h1", text: "Settings"
    choose "Paper", allow_label_click: true
    assert_selector "html[data-scheme=paper]"
    assert_text "Settings saved"
    assert_equal "paper", Setting.current.reload.appearance
    assert_equal "rgb(252, 250, 238)", page.evaluate_script("getComputedStyle(document.body).backgroundColor")
  end
end
