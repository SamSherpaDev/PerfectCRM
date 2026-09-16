class MailSyncState < ApplicationRecord
  # How long a notice stays on the Settings mailbox card. Long enough for
  # the captain to act on a new folder, short enough that the card does not
  # accumulate history he has already dealt with.
  NOTICE_WINDOW = 7.days

  validates :folder, presence: true, uniqueness: true

  scope :recently_noticed, -> { where(last_notice_at: NOTICE_WINDOW.ago..).order(last_notice_at: :desc) }

  def self.for(folder)
    find_or_create_by!(folder: folder.to_s)
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
