class MailSyncState < ApplicationRecord
  # How long a notice or a failure stays on the Settings mailbox card. Long
  # enough for the captain to act on it, short enough that the card does not
  # keep reporting trouble that sync has since recovered from - or trouble
  # in a folder he has since deleted, whose row nothing will ever clear.
  ATTENTION_WINDOW = 7.days

  validates :folder, presence: true, uniqueness: true

  scope :recently_noticed, -> { where(last_notice_at: ATTENTION_WINDOW.ago..).order(last_notice_at: :desc) }
  scope :recently_errored, -> { where(last_error_at: ATTENTION_WINDOW.ago..).order(last_error_at: :desc) }

  # discovered: marks a folder first seen while the mailbox was already
  # syncing, so it is one Outlook gained rather than one the first connect
  # found. Recorded at creation and never inferred again.
  def self.for(folder, discovered: false)
    find_or_create_by!(folder: folder.to_s) do |state|
      state.discovered_at = Time.current if discovered
    end
  end

  # Whether the captain still needs telling about this folder. Discovery and
  # announcement are tracked apart so a failed setup keeps the first and
  # leaves the second, and the notice survives to the run that succeeds.
  def announce?
    discovered_at.present? && announced_at.nil?
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

  # The captain has now been told about this folder, so retrying its setup
  # can never announce it twice.
  def self.record_discovery!(folder, message)
    state = record_notice!(folder, message)
    state.update!(announced_at: Time.current)
    state
  end

  def self.record_error!(folder, message)
    state = self.for(folder)
    state.update!(last_error: message.to_s.truncate(500), last_error_at: Time.current)
    state
  end
end
