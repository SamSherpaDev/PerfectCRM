# Per-message failure boundary for Microsoft Graph mailbox sync.
# Counts the failures that belong to a single message so one unreadable
# message cannot stall later mail in its folder, and stops retrying a message
# after MAX_ATTEMPTS of them so the folder's delta link can advance.
# Which failures count is the reader's rule: Mail::GraphFetcher::LiveRead.
class MailMessageQuarantine < ApplicationRecord
  MAX_ATTEMPTS = 3

  validates :provider_message_id, presence: true, uniqueness: true
  validates :attempts, numericality: { only_integer: true, greater_than_or_equal_to: 0 }

  scope :quarantined, -> { where(attempts: MAX_ATTEMPTS..) }

  def quarantined?
    attempts >= MAX_ATTEMPTS
  end

  def self.quarantined?(provider_message_id)
    return false if provider_message_id.blank?

    quarantined.exists?(provider_message_id: provider_message_id.to_s)
  end

  def self.record_failure!(provider_message_id)
    record = find_or_initialize_by(provider_message_id: provider_message_id.to_s)
    record.attempts += 1
    record.save!
    record
  end

  def self.clear!(provider_message_id)
    return if provider_message_id.blank?

    where(provider_message_id: provider_message_id.to_s).delete_all
  end
end
