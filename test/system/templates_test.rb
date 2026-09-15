require "application_system_test_case"

# The captain answers clients from his phone: creating a template, previewing
# it, and inserting a placeholder must all work one-handed at 390px.
class TemplatesTest < ApplicationSystemTestCase
  setup do
    @key = OpenSSL::PKey::RSA.generate(2048)
    @source = Google::Auth::IDTokens::StaticKeySource.from_jwk_set(
      { keys: [ JWT::JWK.new(@key.public_key).export.merge(alg: "RS256") ] }
    )
    ENV["ALLOWED_GOOGLE_EMAILS"] = "captain@gmail.com"
    ENV["GOOGLE_CLIENT_ID"] = "test-client"
    OmniAuth.config.test_mode = true
    @claims = { "sub" => "google-captain", "email" => "captain@gmail.com", "name" => "Captain",
                "email_verified" => true, "aud" => "test-client", "iss" => "https://accounts.google.com",
                "exp" => 1.hour.from_now.to_i }
  end

  teardown do
    OmniAuth.config.mock_auth.delete(:google_oauth2)
  end

  test "create with live preview and placeholder insert at 390px" do
    sign_in_through_google
    page.current_window.resize_to(390, 844)

    visit templates_path
    assert_no_overflow
    within(".page-actions") { click_link "New template" }

    fill_in "Name", with: "Deposit nudge"
    select "Deposit nudge", from: "Kind of message"
    fill_in "Subject", with: "Holding your {{trip}} seats"
    fill_in "Body", with: "Hi {{first_name}}, please send {{deposit_due}}."

    # The preview pane fills from the sample context without saving.
    within("#template_preview") do
      assert_text "Maya"
      assert_text "$500.00"
      assert_text "Everest Base Camp trek"
    end

    # The chooser drops the token where the cursor sits (end of the body).
    click_button "{{balance_due}}"
    assert_equal "Hi {{first_name}}, please send {{deposit_due}}.{{balance_due}}",
      find_field("Body").value
    within("#template_preview") do
      assert_text "$1,850.00"
    end

    # Focusing the subject first sends the next token there instead (at the
    # click position, proving true cursor insertion rather than appending).
    find_field("Subject").click
    click_button "{{invoice_number}}"
    subject = find_field("Subject").value
    assert_includes subject, "{{invoice_number}}"
    assert_includes subject, "Holding your"
    assert_includes subject, "seats"

    click_button "Create template"
    assert_text "Template saved."
    assert_text "Deposit nudge"
    assert_no_overflow
  end

  test "picker inserts one-handed at 390px and counts the use" do
    Template.create!(name: "Deposit nudge", purpose: "deposit_nudge",
      subject: "Your {{trip}} deposit", body: "Hi {{first_name}}.")
    sign_in_through_google
    page.current_window.resize_to(390, 844)

    visit picker_templates_path
    assert_no_overflow
    assert_button "Insert"
    click_button "Insert"
    assert_selector "button", text: /Inserted/, wait: 5

    visit templates_path
    assert_text "Used once"
    assert_no_overflow
  end

  private

  def sign_in_through_google
    OmniAuth.config.mock_auth[:google_oauth2] = OmniAuth::AuthHash.new(
      provider: "google_oauth2", uid: "google-captain",
      extra: { id_token: JWT.encode(@claims, @key, "RS256") }
    )
    Google::Auth::IDTokens.stub(:oidc_key_source, @source) do
      visit "/auth/google_oauth2/callback"
    end
    assert_text "Today"
  end

  def assert_no_overflow
    width = page.evaluate_script("document.documentElement.scrollWidth")
    assert_operator width, :<=, 390, "#{page.current_path} overflows a 390px viewport (#{width}px)"
  end
end
