class MailSyncState < ApplicationRecord
  # How long a notice or a failure stays on the Settings mailbox card. Long
  # enough for the captain to act on it, short enough that the card does not
  # keep reporting trouble that sync has since recovered from - or trouble
  # in a folder he has since deleted, whose row nothing will ever clear.
  ATTENTION_WINDOW = 7.days

  validates :folder, presence: true, uniqueness: true

  scope :recently_noticed, -> { where(last_notice_at: ATTENTION_WINDOW.ago..).order(last_notice_at: :desc) }
  scope :recently_errored, -> { where(last_error_at: ATTENTION_WINDOW.ago..).order(last_error_at: :desc) }

  # discovered: marks a folder first seen once the mailbox had already been
  # enumerated, so it is one Outlook gained rather than one the first
  # enumeration found. Recorded at creation and never inferred again.
  def self.for(folder, discovered: false)
    find_or_create_by!(folder: folder.to_s) do |state|
      state.discovered_at = Time.current if discovered
    end
  end

  # A watched folder is in exactly one of three states, each read from
  # stored facts rather than from how far some earlier run happened to get:
  #
  #   :watched - primed, with a delta link driving incremental sync.
  #   :new     - the mailbox gained it after it had been enumerated once,
  #              so the mail already in it needs a deliberate import.
  #   :pending - enumerated with the rest but not primed yet, so it holds
  #              no link; it was always there and is not news.
  def folder_state
    return :watched if delta_link.present?

    discovered_at.present? ? :new : :pending
  end

  # Said once, and only for a folder that is genuinely new. Discovery and
  # announcement are separate facts so a failed setup keeps the first and
  # leaves the second, and the notice survives to the run that succeeds.
  def announce?
    folder_state == :new && announced_at.nil?
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
