class MailSyncState < ApplicationRecord
  validates :folder, presence: true, uniqueness: true

  def self.for(folder)
    find_or_create_by!(folder: folder.to_s)
  end

  def self.record_success!(folder, uid_validity:, last_uid:)
    state = self.for(folder)
    state.update!(uid_validity: uid_validity, last_uid: last_uid,
      last_sync_at: Time.current, last_error: nil, last_error_at: nil)
    state
  end

  def self.record_error!(folder, message)
    state = self.for(folder)
    state.update!(last_error: message.to_s.truncate(500), last_error_at: Time.current)
    state
  end
end
