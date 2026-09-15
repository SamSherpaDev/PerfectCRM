require "test_helper"
require_relative "../support/google_sign_in_test_helper"

class DigestSettingsTest < ActionDispatch::IntegrationTest
  include GoogleSignInTestHelper

  setup do
    sign_in
  end

  test "morning digest toggle saves from settings" do
    assert Setting.current.digest_enabled?

    patch settings_path, params: { setting: { digest_enabled: "0" } }
    assert_redirected_to edit_settings_path
    assert_not Setting.current.reload.digest_enabled?

    patch settings_path, params: { setting: { digest_enabled: "1" } }
    assert Setting.current.reload.digest_enabled?

    get edit_settings_path
    assert_response :success
    assert_select "h2", text: "Morning digest"
  end
end
