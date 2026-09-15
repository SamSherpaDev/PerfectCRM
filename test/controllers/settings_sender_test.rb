require "test_helper"
require_relative "../support/google_sign_in_test_helper"

class SettingsSenderTest < ActionDispatch::IntegrationTest
  include GoogleSignInTestHelper

  test "sender name and signature save from Settings" do
    sign_in
    patch settings_path, params: {
      setting: { sender_name: "Sam", email_signature: "Sam Sherpa\nSherpa Holidays" }
    }
    assert_redirected_to edit_settings_path
    settings = Setting.current.reload
    assert_equal "Sam", settings.sender_name
    assert_equal "Sam Sherpa\nSherpa Holidays", settings.email_signature
    follow_redirect!
    assert_select ".flash-notice", text: /saved/
  end

  test "sender settings render on the edit page" do
    sign_in
    get edit_settings_path
    assert_response :success
    assert_select "h2", "Email replies"
    assert_select "label", text: /signature/i
  end
end
