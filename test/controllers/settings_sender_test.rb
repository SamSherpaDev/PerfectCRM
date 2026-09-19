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

  test "legacy formatted param is ignored" do
    Setting.current.update_columns(email_signature_html: "<p>Kept</p>")
    sign_in
    patch settings_path, params: {
      setting: { sender_name: "Sam", email_signature_html: "<p>Dropped</p>" }
    }
    assert_redirected_to edit_settings_path
    assert_equal "<p>Kept</p>", Setting.current.reload.email_signature_html
  end

  test "text falls back to legacy formatted words without another save" do
    Setting.current.update_columns(email_signature: "", email_signature_html: "<p>Sam Sherpa<br>Tel 555-0100</p>")
    assert_equal "Sam Sherpa\nTel 555-0100", EmailSignature.text_for(Setting.current.reload)
  end

  test "legacy identity and safe links survive viewing and saving unchanged lines" do
    Setting.current.update_columns(email_signature: "Sam Sherpa", email_signature_html:
      '<p>Sam Sherpa<br>Sherpa Holidays<br><a href="tel:+15550100">Call Sam</a></p>')
    sign_in
    get edit_settings_path
    assert_response :success
    lines = "Sam Sherpa\nSherpa Holidays\nCall Sam"
    assert_select 'textarea[name="setting[email_signature]"]', text: lines
    assert_select '#signature-preview a[href="tel:+15550100"]', text: "Call Sam"
    patch settings_path, params: { setting: { email_signature: lines.gsub("\n", "\r\n") } }
    assert_redirected_to edit_settings_path
    follow_redirect!
    assert_select '#signature-preview a[href="tel:+15550100"]', text: "Call Sam"
    assert_equal lines, EmailSignature.text_for(Setting.current.reload)
  end

  test "explicit empty submission clears legacy signatures including uninitialized lines" do
    sign_in
    [ "Sam Sherpa", "" ].each do |plain|
      Setting.current.update_columns(email_signature: plain, email_signature_html: "<p>Sam Sherpa</p>")
      patch settings_path, params: { setting: { email_signature: "" } }
      assert_redirected_to edit_settings_path
      settings = Setting.current.reload
      assert_empty settings.email_signature_html
      assert_nil EmailSignature.text_for(settings)
      assert_empty EmailSignature.html_for(settings)
      settings.update!(sender_name: "Sam")
      assert_nil EmailSignature.text_for(settings.reload)
      follow_redirect!
      assert_select 'textarea[name="setting[email_signature]"]', text: ""
      assert_select "#signature-preview table", count: 0
    end
  end

  test "editing signature lines replaces legacy content" do
    Setting.current.update_columns(email_signature: "Sam Sherpa", email_signature_html: "<p>Sam Sherpa<br>Old phone</p>")
    sign_in
    patch settings_path, params: { setting: { email_signature: "Sam Sherpa\r\nNew phone" } }
    assert_redirected_to edit_settings_path
    follow_redirect!
    assert_select "#signature-preview", text: /New phone/
    assert_select "#signature-preview", text: /Old phone/, count: 0
    assert_equal "Sam Sherpa\nNew phone", EmailSignature.text_for(Setting.current.reload)
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

  test "settings page previews the app-owned block with the served logo" do
    sign_in
    Setting.current.signature_logo.attach(
      io: StringIO.new(LOGO_BYTES), filename: "logo.png", content_type: "image/png")
    Setting.current.update!(email_signature: "Sam Sherpa\nFounder, Sherpa Holidays")
    get edit_settings_path
    assert_response :success
    assert_select "#signature-preview table"
    assert_select "#signature-preview img[src=?]", logo_settings_path
    assert_select "label", text: "Signature lines"
    assert_select "label", text: "Formatted signature", count: 0
    assert_select "textarea[name=?]", "setting[email_signature_html]", count: 0
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
