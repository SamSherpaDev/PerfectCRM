require "test_helper"
require_relative "../support/google_sign_in_test_helper"

class PerfectBookSettingsTest < ActionDispatch::IntegrationTest
  include GoogleSignInTestHelper

  test "settings shows unconfigured when no token is set" do
    old = ENV["PERFECTBOOK_API_TOKEN"]
    ENV.delete("PERFECTBOOK_API_TOKEN")
    begin
      sign_in
      get edit_settings_path
      assert_response :success
      assert_select "h2", "PerfectBook connection"
      assert_match(/Unconfigured/, response.body)
      assert_match(/Never/, response.body)
      assert_select "form[action=?]", perfectbook_test_settings_path
    ensure
      ENV["PERFECTBOOK_API_TOKEN"] = old
    end
  end

  test "settings shows configured plus last sync and error" do
    old = ENV["PERFECTBOOK_API_TOKEN"]
    ENV["PERFECTBOOK_API_TOKEN"] = "secret"
    begin
      PerfectBook::SyncState.for("catalog").update!(last_success_at: Time.zone.parse("2026-09-14 10:00"),
        last_error: nil, last_error_at: nil)
      PerfectBook::SyncState.for("contacts").update!(last_error: "bad token", last_error_at: Time.zone.now)
      sign_in
      get edit_settings_path
      assert_response :success
      assert_match(/Configured/, response.body)
      assert_match(/bad token/, response.body)
    ensure
      ENV["PERFECTBOOK_API_TOKEN"] = old
    end
  end

  test "test connection succeeds with a stubbed client" do
    ok_client = Object.new
    def ok_client.test_connection
      true
    end
    PerfectBook::Client.stub(:new, ok_client) do
      sign_in
      post perfectbook_test_settings_path
      assert_redirected_to edit_settings_path
      follow_redirect!
      assert_match(/works/, response.body)
    end
  end

  test "test connection reports an unconfigured API" do
    failing = Object.new
    def failing.test_connection
      raise PerfectBook::NotConfiguredError, "missing"
    end
    PerfectBook::Client.stub(:new, failing) do
      sign_in
      post perfectbook_test_settings_path
      assert_redirected_to edit_settings_path
      follow_redirect!
      assert_match(/not configured/i, response.body)
    end
  end

  test "test connection reports a rejected token" do
    failing = Object.new
    def failing.test_connection
      raise PerfectBook::UnauthorizedError, "nope"
    end
    PerfectBook::Client.stub(:new, failing) do
      sign_in
      post perfectbook_test_settings_path
      assert_redirected_to edit_settings_path
      follow_redirect!
      assert_match(/rejected/, response.body)
    end
  end

  test "settings test requires sign in" do
    post perfectbook_test_settings_path
    assert_redirected_to sign_in_path
  end
end
