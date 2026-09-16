class MailSyncState < ApplicationRecord
  validates :folder, presence: true, uniqueness: true

  def self.for(folder)
    find_or_create_by!(folder: folder.to_s)
  end

  def self.record_success!(folder, delta_link:)
    state = self.for(folder)
    state.update!(delta_link: delta_link,
      last_sync_at: Time.current, last_error: nil, last_error_at: nil)
    state
  end

  def self.record_error!(folder, message)
    state = self.for(folder)
    state.update!(last_error: message.to_s.truncate(500), last_error_at: Time.current)
    state
  end
end
