require "digest"

# Only a digest is persisted. The browser carries an opaque, random token;
# deleting this row revokes even a copy of the encrypted browser cookie.
class LoginSession < ApplicationRecord
  belongs_to :user
  validates :token_digest, :expires_at, presence: true

  def self.issue!(user)
    token = SecureRandom.urlsafe_base64(32)
    create!(user: user, token_digest: Digest::SHA256.hexdigest(token), expires_at: Rails.configuration.x.staff_session_idle_timeout.from_now)
    token
  end

  def self.for_token(token)
    find_by(token_digest: Digest::SHA256.hexdigest(token)) if token.present?
  end

  def renew!
    update!(expires_at: Rails.configuration.x.staff_session_idle_timeout.from_now)
  end
end
