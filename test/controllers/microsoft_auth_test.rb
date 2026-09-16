require "test_helper"
require_relative "../support/google_sign_in_test_helper"

class MicrosoftAuthTest < ActionDispatch::IntegrationTest
  include GoogleSignInTestHelper

  setup do
    sign_in
    post mailbox_connect_settings_path
    @state = session[:microsoft_auth_state]
    assert @state.present?
  end

  test "callback exchanges the code and connects the mailbox" do
    connected = false
    Mail::GraphAuth.stub(:connect!, ->(**) {
      connected = true
      Setting.current.update!(ms_graph_refresh_token: "refresh-cb")
    }) do
      get microsoft_callback_path, params: { code: "auth-code", state: @state }
    end
    assert connected
    assert_redirected_to edit_settings_path
    assert_match(/connected/i, flash[:notice].to_s)
    assert Setting.current.reload.mailbox_connected?
  end

  test "callback rejects a mismatched state without exchanging" do
    exchanged = false
    Mail::GraphAuth.stub(:connect!, ->(**) { exchanged = true }) do
      get microsoft_callback_path, params: { code: "auth-code", state: "wrong-state" }
    end
    assert_not exchanged
    assert_redirected_to edit_settings_path
    assert_match(/interrupted/i, flash[:alert].to_s)
    assert_not Setting.current.reload.mailbox_connected?
  end

  test "callback names the wrong account and connects nothing" do
    Mail::GraphAuth.stub(:connect!, ->(**) {
      raise Mail::WrongMailboxError, "Microsoft signed in as sam@personal.example, not info@sherpaholidays.com."
    }) do
      get microsoft_callback_path, params: { code: "auth-code", state: @state }
    end
    assert_redirected_to edit_settings_path
    assert_match(/sam@personal\.example/, flash[:alert].to_s)
    assert_not Setting.current.reload.mailbox_connected?
  end

  test "the authorization code never reaches the request log" do
    get microsoft_callback_path, params: { code: "0.AXoAsecret-code", state: "wrong-state" }
    assert_not_includes request.filtered_path, "0.AXoAsecret-code"
    assert_includes request.filtered_path, "[FILTERED]"
  end

  test "callback surfaces a Microsoft refusal" do
    get microsoft_callback_path, params: { error: "access_denied", state: @state }
    assert_redirected_to edit_settings_path
    assert_match(/access_denied/, flash[:alert].to_s)
  end

  test "callback failure to exchange asks to retry" do
    Mail::GraphAuth.stub(:connect!, ->(**) { raise Mail::ConnectionError, "down" }) do
      get microsoft_callback_path, params: { code: "auth-code", state: @state }
    end
    assert_redirected_to edit_settings_path
    assert_match(/Try Connect mailbox again/i, flash[:alert].to_s)
  end
end
