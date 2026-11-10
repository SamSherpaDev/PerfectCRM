# Per-message failure boundary for Microsoft Graph mailbox sync.
# Tracks single messages that raise while loading or storing so one unreadable
# message cannot stall later mail in its folder, and stops retrying a message
# after MAX_ATTEMPTS failed attempts so the folder's delta link can advance.
class MailMessageQuarantine < ApplicationRecord
  MAX_ATTEMPTS = 3

  alias_attribute :message_id, :provider_message_id
  alias_attribute :attempt_count, :attempts
  alias_attribute :error_message, :last_error

  validates :provider_message_id, presence: true, uniqueness: true
  validates :error_class, presence: true
  validates :attempts, numericality: { only_integer: true, greater_than_or_equal_to: 0 }

  scope :quarantined, -> { where(attempts: MAX_ATTEMPTS..) }

  def quarantined?
    attempts >= MAX_ATTEMPTS
  end

  def self.quarantined?(provider_message_id)
    return false if provider_message_id.blank?

    quarantined.exists?(provider_message_id: provider_message_id.to_s)
  end

  def self.record_failure!(provider_message_id:, error:, folder: nil)
    now = Time.current
    record = find_or_initialize_by(provider_message_id: provider_message_id.to_s)
    record.folder = folder.to_s.presence || record.folder
    record.error_class = error.class.name
    record.last_error = error.message.to_s.truncate(500)
    record.attempts = record.attempts.to_i + 1
    record.last_failed_at = now
    record.quarantined_at ||= now if record.quarantined?
    record.save!
    record
  end

  def self.clear!(provider_message_id)
    return if provider_message_id.blank?

    where(provider_message_id: provider_message_id.to_s).delete_all
  end
end
