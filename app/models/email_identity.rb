class EmailIdentity < ApplicationRecord
  belongs_to :linkable, polymorphic: true, optional: true

  before_validation :normalize_email

  validates :email, presence: true, uniqueness: true,
    format: { with: URI::MailTo::EMAIL_REGEXP }

  scope :ordered, -> { order(:email) }

  def self.normalized(address)
    address.to_s.strip.downcase
  end

  def self.find_for(address)
    find_by(email: normalized(address))
  end

  # Remember a triage decision so later mail from the same sender auto-links.
  def self.remember!(address, linkable: nil, ignored: false)
    email = normalized(address)
    return nil if email.blank?

    record = find_or_initialize_by(email: email)
    record.linkable = linkable
    record.ignored = !!ignored
    record.last_confirmed_at = Time.current
    record.save!
    record
  end

  private

  def normalize_email
    self.email = self.class.normalized(email)
  end
end
