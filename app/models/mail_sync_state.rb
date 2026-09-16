class MailSyncState < ApplicationRecord
  # How long a notice or a failure stays on the Settings mailbox card. Long
  # enough for the captain to act on it, short enough that the card does not
  # keep reporting trouble that sync has since recovered from - or trouble
  # in a folder he has since deleted, whose row nothing will ever clear.
  ATTENTION_WINDOW = 7.days

  validates :folder, presence: true, uniqueness: true

  scope :recently_noticed, -> { where(last_notice_at: ATTENTION_WINDOW.ago..).order(last_notice_at: :desc) }
  scope :recently_errored, -> { where(last_error_at: ATTENTION_WINDOW.ago..).order(last_error_at: :desc) }

  def self.for(folder)
    find_or_create_by!(folder: folder.to_s)
  end

  # Live sync covers mail received from the moment a folder is first
  # watched; anything older is Import history's to bring in. Graph reports
  # receivedDateTime to the second, so the boundary is kept to the second
  # too, or mail landing in the same second as the first watch would read
  # as older than it.
  def watched_since
    created_at.change(usec: 0)
  end

  def self.record_success!(folder, delta_link:)
    state = self.for(folder)
    state.update!(delta_link: delta_link,
      last_sync_at: Time.current, last_error: nil, last_error_at: nil)
    state
  end

  # Something worth the captain's attention that is not a failure, so
  # routine success does not clear it.
  def self.record_notice!(folder, message)
    state = self.for(folder)
    state.update!(last_notice: message.to_s.truncate(500), last_notice_at: Time.current)
    state
  end

  def self.record_error!(folder, message)
    state = self.for(folder)
    state.update!(last_error: message.to_s.truncate(500), last_error_at: Time.current)
    state
  end
end
