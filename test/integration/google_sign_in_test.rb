require "test_helper"
require_relative "../support/google_sign_in_test_helper"

class GoogleSignInTest < ActionDispatch::IntegrationTest
  include GoogleSignInTestHelper

  test "allowed verified Google identity signs in and updates by subject" do
    assert_difference "User.count", 1 do
      sign_in
    end
    assert_redirected_to root_path
    follow_redirect!
    assert_response :success
    assert_includes response.body, "Welcome, Captain"
    user = User.find_by!(google_sub: "google-captain")
    assert_in_delta Time.current.to_i, user.last_signed_in_at.to_i, 1

    @claims.merge!("email" => "other@gmail.com", "name" => "Updated Captain")
    assert_no_difference "User.count" do
      sign_in
    end
    assert_equal "other@gmail.com", user.reload.email
    assert_equal "Updated Captain", user.name
  end

  test "email does not link different Google subjects" do
    sign_in
    @claims["sub"] = "another-subject"
    assert_difference "User.count", 1 do
      sign_in
    end
  end

  test "non allowlisted email is forbidden and clears an existing session" do
    sign_in
    @claims["email"] = "stranger@gmail.com"
    assert_no_difference "User.count" do
      sign_in
    end
    assert_not_allowed
  end

  test "unverified email including truthy strings fails verification" do
    [ false, "true", nil ].each do |verified|
      @claims["email_verified"] = verified
      sign_in
      assert_sign_in_failed
    end
    assert_equal 0, User.count
  end

  test "empty allowlist fails closed" do
    ENV["ALLOWED_GOOGLE_EMAILS"] = ""
    sign_in
    assert_not_allowed
  end

  test "wrong audience issuer expired or missing claims fail verification" do
    { "aud" => "other-client", "iss" => "https://attacker.test", "exp" => 1.minute.ago.to_i, "sub" => "" }.each do |claim, value|
      original = @claims[claim]
      @claims[claim] = value
      sign_in
      assert_sign_in_failed
      @claims[claim] = original
    end
    @claims.delete("exp")
    sign_in
    assert_sign_in_failed
    assert_equal 0, User.count
  end

  test "forged signature fails verification" do
    sign_in(key: OpenSSL::PKey::RSA.generate(2048))
    assert_sign_in_failed
    assert_equal 0, User.count
  end

  test "protected root redirects to sign in while health stays open" do
    get root_path
    assert_redirected_to sign_in_path
    follow_redirect!
    assert_select "form[action='/auth/google_oauth2'][method='post']"
    get "/up"
    assert_response :success
  end

  test "session expires after twelve inactive hours but activity renews it" do
    sign_in
    travel 11.hours do
      get root_path
      assert_response :success
    end
    travel 22.hours do
      get root_path
      assert_response :success
    end
    travel 35.hours do
      get root_path
      assert_redirected_to sign_in_path
    end
  end

  test "sign out and allowlist removal both revoke access" do
    sign_in
    delete sign_out_path
    assert_redirected_to sign_in_path
    get root_path
    assert_redirected_to sign_in_path
    sign_in
    ENV["ALLOWED_GOOGLE_EMAILS"] = ""
    get root_path
    assert_redirected_to sign_in_path
  end

  test "sign in POST requires CSRF and keeps scopes fixed" do
    original_protection = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
    OmniAuth.config.test_mode = false
    post "/auth/google_oauth2"
    assert_redirected_to %r{/auth/failure}

    get sign_in_path
    token = css_select("input[name='authenticity_token']").first["value"]
    post "/auth/google_oauth2", params: { authenticity_token: token, scope: "calendar", state: "attacker" }
    assert_response :redirect
    query = Rack::Utils.parse_query(URI.parse(response.location).query)
    assert_equal "https://accounts.google.com", "#{URI.parse(response.location).scheme}://#{URI.parse(response.location).host}"
    assert_equal %w[email openid profile], query.fetch("scope").split.sort
    assert_not_equal "attacker", query.fetch("state")
  ensure
    ActionController::Base.allow_forgery_protection = original_protection
  end

  test "cancelled Google consent shows a retry page and keeps an existing session" do
    sign_in
    OmniAuth.config.mock_auth[:google_oauth2] = :access_denied
    get "/auth/google_oauth2/callback"
    assert_redirected_to %r{\A/auth/failure\?message=access_denied}
    follow_redirect!
    assert_response :unprocessable_content
    assert_includes response.body, "Sign-in failed"
    assert_not_includes response.body, "not allowed"
    assert_signed_in
  end

  test "stray visit to auth failure keeps a signed-in user signed in" do
    sign_in
    get "/auth/failure"
    assert_response :unprocessable_content
    assert_includes response.body, "Sign-in failed"
    assert_signed_in
  end

  test "auth failure renders for an anonymous visitor" do
    get "/auth/failure"
    assert_response :unprocessable_content
    assert_includes response.body, "Sign-in failed"
    assert_signed_out
  end

  private

  def assert_not_allowed
    assert_response :forbidden
    assert_includes response.body, "This Google account is not allowed"
    assert_signed_out
  end

  def assert_sign_in_failed
    assert_response :unprocessable_content
    assert_includes response.body, "Sign-in failed"
    assert_not_includes response.body, "not allowed"
    assert_signed_out
  end

  def assert_signed_out
    get root_path
    assert_redirected_to sign_in_path
  end

  def assert_signed_in
    get root_path
    assert_response :success
  end
end
