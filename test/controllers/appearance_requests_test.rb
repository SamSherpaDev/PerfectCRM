require "test_helper"
require_relative "../support/google_sign_in_test_helper"

class AppearanceRequestsTest < ActionDispatch::IntegrationTest
  include GoogleSignInTestHelper

  test "paper is the default scheme for signed-in pages" do
    sign_in
    get root_path
    assert_response :success
    assert_select "html[data-scheme=paper]"
    assert_select "meta[name=theme-color][content='#fcfaee']"
  end

  test "signed-out pages render on paper" do
    get sign_in_path
    assert_response :success
    assert_select "html[data-scheme=paper]"
  end

  test "saving night in settings switches the scheme and the theme colour" do
    sign_in
    patch settings_path, params: { setting: { appearance: "night" } }
    assert_redirected_to edit_settings_path
    assert_equal "night", Setting.current.reload.appearance
    get root_path
    assert_select "html[data-scheme=night]"
    assert_select "body[data-scheme=night]"
    assert_select "meta[name=theme-color][content='#14110e']"
  end

  test "settings page offers only paper and night" do
    sign_in
    get edit_settings_path
    assert_response :success
    assert_select "input[type=radio][name='setting[appearance]'][value=paper][checked]"
    assert_select "input[type=radio][name='setting[appearance]'][value=night]"
    assert_select "input[type=radio][name='setting[appearance]']", count: 2
  end

  test "an unknown appearance is rejected" do
    sign_in
    patch settings_path, params: { setting: { appearance: "device" } }
    assert_response :unprocessable_entity
    assert_equal "paper", Setting.current.reload.appearance
  end

  test "appearance saves return only a status update to Turbo" do
    sign_in
    patch settings_path, params: { setting: { appearance: "night" } },
      headers: { "Accept" => "text/vnd.turbo-stream.html" }
    assert_response :success
    assert_equal "night", Setting.current.reload.appearance
    assert_select "turbo-stream", count: 1
    assert_select 'turbo-stream[action="update"][target="appearance-status"] template', text: "Settings saved."
  end
end
