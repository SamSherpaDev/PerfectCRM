require "test_helper"
require_relative "../support/google_sign_in_test_helper"

class SettingsSenderTest < ActionDispatch::IntegrationTest
  include GoogleSignInTestHelper

  test "sender name and signature save from Settings" do
    sign_in
    patch settings_path, params: {
      setting: { sender_name: "Sam", email_signature: "Sam Sherpa\r\nSherpa Holidays" }
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
    assert_select "h2", "Signature"
    assert_select "label", text: /signature/i
  end

  test "formatted signature saves sanitized" do
    sign_in
    patch settings_path, params: {
      setting: { email_signature_html: "<p>Sam Sherpa</p><script>alert(1)</script>" }
    }
    assert_redirected_to edit_settings_path
    assert_equal "<p>Sam Sherpa</p>", Setting.current.reload.email_signature_html
  end

  test "text follows the formatted signature when only HTML is supplied" do
    sign_in
    patch settings_path, params: {
      setting: { email_signature: "", email_signature_html: "<p>Sam Sherpa<br>Tel 555-0100</p>" }
    }
    assert_redirected_to edit_settings_path
    assert_equal "", Setting.current.reload.email_signature
    assert_equal "Sam Sherpa\nTel 555-0100", EmailSignature.text_for(Setting.current)

    patch settings_path, params: {
      setting: { email_signature: "", email_signature_html: "<p>Sam Sherpa<br>Tel 555-0200</p>" }
    }
    assert_redirected_to edit_settings_path
    assert_equal "Sam Sherpa\nTel 555-0200", EmailSignature.text_for(Setting.current.reload)
  end

  test "logo upload attaches a PNG" do
    sign_in
    patch settings_path, params: { setting: { signature_logo: uploaded_logo } }
    assert_redirected_to edit_settings_path
    assert Setting.current.reload.signature_logo.attached?
    follow_redirect!
    assert_select "img[alt='Signature logo']"
  end

  test "logo upload rejects SVG with a plain message" do
    sign_in
    patch settings_path, params: {
      setting: { signature_logo: Rack::Test::UploadedFile.new(
        StringIO.new('<svg xmlns="http://www.w3.org/2000/svg"></svg>'),
        "image/svg+xml", original_filename: "logo.svg") }
    }
    assert_response :unprocessable_entity
    assert_not Setting.current.reload.signature_logo.attached?
    assert_match(/must be a PNG, JPEG, or GIF/, response.body)
  end

  test "logo upload rejects oversize files with a plain message" do
    sign_in
    patch settings_path, params: {
      setting: { signature_logo: Rack::Test::UploadedFile.new(
        StringIO.new("x" * (500.kilobytes + 1)),
        "image/png", original_filename: "big.png") }
    }
    assert_response :unprocessable_entity
    assert_not Setting.current.reload.signature_logo.attached?
    assert_match(/must be under 500 KB/, response.body)
  end

  test "logo serves through the controller, 404 when missing" do
    sign_in
    get logo_settings_path
    assert_response :not_found
    Setting.current.signature_logo.attach(
      io: StringIO.new(LOGO_BYTES), filename: "logo.png", content_type: "image/png")
    get logo_settings_path
    assert_response :success
    assert_equal "image/png", response.media_type
  end

  test "remove logo purges the attachment" do
    sign_in
    Setting.current.signature_logo.attach(
      io: StringIO.new(LOGO_BYTES), filename: "logo.png", content_type: "image/png")
    delete signature_logo_settings_path
    assert_redirected_to edit_settings_path
    assert_not Setting.current.reload.signature_logo.attached?
  end

  test "settings page previews the saved signature with the served logo" do
    sign_in
    Setting.current.signature_logo.attach(
      io: StringIO.new(LOGO_BYTES), filename: "logo.png", content_type: "image/png")
    Setting.current.update!(email_signature_html: "<p>Sam Sherpa</p><img src=\"https://tracker.example/p.gif\">")
    get edit_settings_path
    assert_response :success
    assert_select "#signature-preview p", text: "Sam Sherpa"
    assert_select "#signature-preview img[src=?]", logo_settings_path
    assert_select "#signature-preview img[src*=?]", "tracker.example", count: 0
  end

  teardown do
    setting = Setting.current
    setting.signature_logo.purge if setting.signature_logo.attached?
    setting.update!(email_signature: "", email_signature_html: "")
  end

  LOGO_BYTES = Base64.decode64(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
  ).freeze
  private_constant :LOGO_BYTES

  def uploaded_logo
    Rack::Test::UploadedFile.new(
      StringIO.new(LOGO_BYTES), "image/png", original_filename: "logo.png")
  end
end
