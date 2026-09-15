class GoogleIdentity
  class Unverified < StandardError; end
  class NotAllowed < StandardError; end

  def self.claims(auth)
    raise Unverified unless auth && auth["provider"] == "google_oauth2"

    claims = if Rails.env.development? && ENV["GOOGLE_AUTH_TEST_MODE"] == "true" && OmniAuth.config.test_mode
      auth.dig("extra", "id_info")
    else
      audience = ENV["GOOGLE_CLIENT_ID"].presence
      token = auth.dig("extra", "id_token").presence
      raise Unverified unless audience && token
      Google::Auth::IDTokens.verify_oidc(token, aud: audience)
    end

    raise Unverified unless claims && claims["sub"].is_a?(String) && claims["sub"].present?
    unless Rails.env.development? && ENV["GOOGLE_AUTH_TEST_MODE"] == "true" && OmniAuth.config.test_mode
      raise Unverified unless claims["exp"].is_a?(Numeric) && claims["exp"] > Time.current.to_i
    end
    raise Unverified unless claims["email_verified"] == true
    raise NotAllowed unless User.allowed_email?(claims["email"])
    claims
  rescue Google::Auth::IDTokens::VerificationError, Google::Auth::IDTokens::KeySourceError
    raise Unverified
  end
end
