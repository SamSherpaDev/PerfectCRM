# Retires the Gmail login + app password in favour of the Microsoft 365
# delegated grant: only the refresh token is stored (encrypted on Setting).
# Clearing both columns disconnects the old reader; the captain reconnects
# with "Connect mailbox" in Settings.
class MicrosoftGraphMailboxAuth < ActiveRecord::Migration[8.1]
  def up
    add_column :settings, :ms_graph_refresh_token, :text
    remove_column :settings, :mailbox_login, :string
    remove_column :settings, :mailbox_app_password, :string
  end

  def down
    add_column :settings, :mailbox_login, :string
    add_column :settings, :mailbox_app_password, :string
    remove_column :settings, :ms_graph_refresh_token, :text
  end
end
