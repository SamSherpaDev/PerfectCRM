class Setting < ApplicationRecord
  APPEARANCES = %w[paper night].freeze

  has_one_attached :signature_logo

  encrypts :relay_secret, deterministic: false

  encrypts :ms_graph_refresh_token
  encrypts :ai_api_key


  validates :ai_daily_cost_cap_cents, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :ai_rate_limit_per_minute, numericality: { only_integer: true, greater_than_or_equal_to: 1, less_than_or_equal_to: 120 }

  validates :singleton_key, inclusion: { in: [ 1 ] }, uniqueness: true
  validates :appearance, inclusion: { in: APPEARANCES }
  validates :lead_webhook_url, format: { with: %r{\Ahttps?://[^\s/]+(?:/[^\s]*)?\z}, allow_blank: true }
  validate :signature_logo_requirements

  before_save :normalize_signature

  def self.current
    find_by(singleton_key: 1) || create_or_find_by!(singleton_key: 1)
  end

  # Delegated Microsoft 365 grant: connected once a refresh token is stored
  # along with when the mailbox started being watched.
  def mailbox_connected?
    ms_graph_refresh_token.present? && mailbox_watched_since.present?
  end

  # The stored refresh token outlives a grant Microsoft revoked; sync or Test
  # connection records that as the last error until a reconnect, a clean
  # sync, or a working Test connection clears it.
  def mailbox_grant_revoked?
    mailbox_connected? && mailbox_last_error == Mail::GraphClient::REVOKED
  end

  def webhooks_enabled?
    lead_webhook_url.present?
  end

  # Public storefront identifier for browser-mode intake. Shown in Settings.
  def rotate_site_key!
    update!(site_key: "sh_site_#{SecureRandom.alphanumeric(24)}")
    site_key
  end

  # Shared secret for relay HMAC and outbound webhook signing. The plaintext
  # is shown once right after rotation, then only masked.
  def rotate_relay_secret!
    secret = "sh_relay_#{SecureRandom.alphanumeric(32)}"
    update!(relay_secret: secret)
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
  end

  private

  # The email logo: PNG, JPEG, or GIF around 500 KB. No SVG, which mail
  # clients do not render.
  def signature_logo_requirements
    return unless signature_logo.attached?

    blob = signature_logo.blob
    unless EmailSignature::LOGO_TYPES.include?(blob.content_type)
      errors.add(:signature_logo, "must be a PNG, JPEG, or GIF")
    end
    if blob.byte_size > EmailSignature::MAX_LOGO_BYTES
      errors.add(:signature_logo, "must be under 500 KB")
    end
  end

  # Browser textareas submit CRLF; the signature is matched against LF
  # bodies, so both signature shapes are stored with LF line endings.
  # When the editable lines are blank but the legacy formatted column
  # still holds words, those words move into the lines on save so the
  # app-owned block keeps rendering them with the logo. The legacy
  # column itself is never cleared here.
  def normalize_signature
    self.email_signature = email_signature&.gsub("\r\n", "\n")
    self.email_signature_html = EmailSignature.sanitize(email_signature_html)
    if email_signature.blank?
      derived = EmailSignature.text_from_html(email_signature_html)
      self.email_signature = derived if derived.present?
    end
  end
end
