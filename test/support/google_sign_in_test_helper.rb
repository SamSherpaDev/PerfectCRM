require "minitest/mock"

module GoogleSignInTestHelper
  extend ActiveSupport::Concern

  included do
    setup do
      @old_env = ENV.to_h.slice("ALLOWED_GOOGLE_EMAILS", "GOOGLE_CLIENT_ID")
      ENV["ALLOWED_GOOGLE_EMAILS"] = " captain@gmail.com , other@gmail.com "
      ENV["GOOGLE_CLIENT_ID"] = "test-client"
      @old_test_mode = OmniAuth.config.test_mode
      OmniAuth.config.test_mode = true
      @key = OpenSSL::PKey::RSA.generate(2048)
      @source = Google::Auth::IDTokens::StaticKeySource.from_jwk_set(
        { keys: [ JWT::JWK.new(@key.public_key).export.merge(alg: "RS256") ] }
      )
      @claims = { "sub" => "google-captain", "email" => "CAPTAIN@gmail.com", "name" => "Captain",
                  "email_verified" => true, "aud" => "test-client", "iss" => "https://accounts.google.com",
                  "exp" => 1.hour.from_now.to_i }
    end

    teardown do
      %w[ALLOWED_GOOGLE_EMAILS GOOGLE_CLIENT_ID].each { |key| ENV[key] = @old_env[key] }
      OmniAuth.config.test_mode = @old_test_mode
      OmniAuth.config.mock_auth.delete(:google_oauth2)
    end
  end

  private

  def sign_in(key: @key)
    OmniAuth.config.mock_auth[:google_oauth2] = OmniAuth::AuthHash.new(
      provider: "google_oauth2", uid: "untrusted-profile-subject",
      extra: { id_token: JWT.encode(@claims, key, "RS256") }
    )
    Google::Auth::IDTokens.stub(:oidc_key_source, @source) do
      get "/auth/google_oauth2/callback"
    end
  end
end
