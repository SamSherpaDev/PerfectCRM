# Be sure to restart your server when you modify this file.

# Configure parameters to be partially matched (e.g. passw matches password) and filtered from the log file.
# Use this to limit dissemination of sensitive information.
# See the ActiveSupport::ParameterFilter documentation for supported notations and behaviors.
Rails.application.config.filter_parameters += [
  :passw, :email, :phone, :recipients, :secret, :token, :_key, :crypt, :salt, :certificate, :otp, :ssn, :cvv, :cvc,
  # PerfectBook sibling-API token: never log it (client logs status only).
  /\A(?:to|cc|bcc)\z/, :perfectbook_api_token,
  # OAuth authorization codes arrive as query parameters on the Google and
  # Microsoft callbacks, and an unredeemed one must not sit in the logs.
  /\Acode\z/,
  # Hide channel check payloads, including campaign and ad names in spend requests.
  :snapshot, /\Aspends?\z/
]

# Request parameters are customer-controlled, including nested intake metadata,
# composer text and search queries. Retain only routing fields, rather than
# chasing every new identity/free-text field as the intake evolves.
Rails.application.config.filter_parameters << /\A(?!(?:controller|action|id|format)\z)/

# Redirect notifications otherwise log the public quote's bearer capability.
Rails.application.config.filter_redirect << %r{/q/}
