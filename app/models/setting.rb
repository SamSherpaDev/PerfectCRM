class Setting < ApplicationRecord
  APPEARANCES = %w[paper night].freeze
  DEFAULT_INTAKE_COPY_TO = "info@sherpaholidays.com"
  AUTOMATION_MAY = "Create leads, score them, and move them between New, Chatting and Lost."
  AUTOMATION_MANUAL = "Quoted, Nudged, conversion to client, and everything after stay manual."

  encrypts :relay_secret, deterministic: false

  serialize :lead_webhooks, coder: JSON

  encrypts :mailbox_app_password

  validates :singleton_key, inclusion: { in: [ 1 ] }, uniqueness: true
  validates :appearance, inclusion: { in: APPEARANCES }
  # One URL per line in the form; stored as an array.
  def lead_webhook_urls
    Array(lead_webhooks).map(&:to_s).map(&:strip).reject(&:blank?)
      .select { |url| url.start_with?("http://", "https://") }.uniq.first(10)
  end

  def lead_webhook_urls_text
    Array(lead_webhooks).map(&:to_s).join("\n")
  end

  def webhooks_enabled?
    lead_webhook_urls.any?
  end

  # Public storefront identifier for browser-mode intake. Shown in Settings.
  def rotate_site_key!
    update!(
      site_key: "sh_site_#{SecureRandom.alphanumeric(24)}",
      site_key_version: site_key_version.to_i + 1
    )
    site_key
  end

  # Shared secret for relay HMAC and outbound webhook signing. The plaintext
  # is shown once right after rotation, then only masked.
  def rotate_relay_secret!
    secret = "sh_relay_#{SecureRandom.alphanumeric(32)}"
    update!(relay_secret: secret, relay_secret_version: relay_secret_version.to_i + 1)
    secret
  end

  def masked_relay_secret
    return "Not set" if relay_secret.blank?

    "••••#{relay_secret.to_s.last(4)}"
  end

  def ensure_intake_credentials!
    rotate_site_key! if site_key.blank?
    rotate_relay_secret! if relay_secret.blank?
    self
