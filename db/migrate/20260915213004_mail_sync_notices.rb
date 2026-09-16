# Per-folder notices the captain needs to see but that are not failures: a
# sync token Microsoft expired and the gap that was re-read to fill it.
class MailSyncNotices < ActiveRecord::Migration[8.1]
  def change
    add_column :mail_sync_states, :last_notice, :text
    add_column :mail_sync_states, :last_notice_at, :datetime
  end
end
