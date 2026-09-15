require "test_helper"
require_relative "../support/google_sign_in_test_helper"

class MailboxSettingsTest < ActionDispatch::IntegrationTest
  include GoogleSignInTestHelper

  setup do
    sign_in
  end

  test "settings shows the fixed mailbox address and help text" do
    get edit_settings_path
    assert_response :success
    assert_select "h2", text: "Mailbox"
    assert_match Mail.mailbox_address, response.body
    assert_match(/App passwords/, response.body)
  end

  test "mailbox login saves and the password stays encrypted" do
    patch mailbox_settings_path, params: { setting: { mailbox_login: "captain@gmail.com", mailbox_app_password: "abcd-efgh" } }
    assert_redirected_to edit_settings_path
    settings = Setting.current.reload
    assert_equal "captain@gmail.com", settings.mailbox_login
    raw = Setting.connection.select_value("SELECT mailbox_app_password FROM settings WHERE id = #{settings.id}")
    assert_not_includes raw.to_s, "abcd-efgh"
    assert_equal "abcd-efgh", settings.mailbox_app_password
  end

  test "mailbox test without credentials warns" do
    Setting.current.update!(mailbox_login: nil, mailbox_app_password: nil)
    post mailbox_test_settings_path
    assert_redirected_to edit_settings_path
    assert_match(/app password/i, flash[:alert].to_s)
  end
end
