Rails.application.configure do
  config.content_security_policy do |policy|
    policy.default_src :self
    policy.script_src :self
    # Progress bars, layouts and Stimulus animations use style attributes.
    # Scripts still require a nonce and never allow inline handlers.
    policy.style_src :self, :unsafe_inline
    policy.img_src :self, :data
    policy.font_src :self
    policy.connect_src :self
    policy.object_src :none
    policy.base_uri :none
    policy.frame_ancestors :none
    # OAuth begins with a same-origin POST which redirects to the provider.
    policy.form_action :self, "https://accounts.google.com", "https://login.microsoftonline.com"
  end

  # Turbo retains its document head during visits. Keep the random nonce
  # stable within a session so it can activate subsequent importmaps.
  config.content_security_policy_nonce_generator = ->(request) { request.session[:csp_nonce] ||= SecureRandom.base64(32) }
  config.content_security_policy_nonce_directives = %w[script-src]
end
