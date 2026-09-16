# Retires the IMAP UID cursor in favour of the Graph delta link, persisted
# per folder (inbox + sentitems). The stale "[Gmail]/All Mail" row holds a
# meaningless UID cursor, so it is removed; affected folders re-prime on the
# next sync, which stores nothing (see Mail::GraphFetcher).
class GraphDeltaSyncState < ActiveRecord::Migration[8.1]
  def up
    add_column :mail_sync_states, :delta_link, :text
    remove_column :mail_sync_states, :last_uid, :integer
    remove_column :mail_sync_states, :uid_validity, :integer
    execute "DELETE FROM mail_sync_states WHERE folder = '[Gmail]/All Mail'"
  end

  def down
    execute "DELETE FROM mail_sync_states WHERE folder IN ('inbox', 'sentitems')"
    add_column :mail_sync_states, :last_uid, :integer, default: 0, null: false
    add_column :mail_sync_states, :uid_validity, :integer
    remove_column :mail_sync_states, :delta_link
  end
end
