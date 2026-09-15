class Setting < ApplicationRecord
  APPEARANCES = %w[paper night].freeze

  encrypts :mailbox_app_password

  validates :singleton_key, inclusion: { in: [ 1 ] }, uniqueness: true
  validates :appearance, inclusion: { in: APPEARANCES }
  validates :mailbox_login, format: { with: URI::MailTo::EMAIL_REGEXP, allow_blank: true }

  def self.current
    find_by(singleton_key: 1) || create_or_find_by!(singleton_key: 1)
  end

  def mailbox_configured?
    mailbox_login.present? && mailbox_app_password.present?
  end
end
