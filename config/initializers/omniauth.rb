OmniAuth.config.allowed_request_methods = [ :post ]
OmniAuth.config.on_failure = OmniAuth::FailureEndpoint

Rails.application.config.middleware.use OmniAuth::Builder do
  provider :google_oauth2, ENV["GOOGLE_CLIENT_ID"], ENV["GOOGLE_CLIENT_SECRET"],
    scope: "openid,email,profile", access_type: "online", prompt: "select_account",
    overridable_authorize_options: [], provider_ignores_state: false
end

# Never enable mock identities outside development.
if Rails.env.development? && ENV["GOOGLE_AUTH_TEST_MODE"] == "true"
  OmniAuth.config.test_mode = true
  OmniAuth.config.mock_auth[:google_oauth2] = OmniAuth::AuthHash.new(
    provider: "google_oauth2", uid: "development-captain",
    extra: { id_info: { sub: "development-captain", email: "captain@example.test",
                       email_verified: true, name: "Captain (development)" } }
  )
end
