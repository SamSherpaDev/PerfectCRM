class AddMailboxToSettings < ActiveRecord::Migration[8.1]
  def change
    add_column :settings, :mailbox_login, :string
    add_column :settings, :mailbox_app_password, :string
    add_column :settings, :mailbox_last_sync_at, :datetime
    add_column :settings, :mailbox_last_error, :text
    add_column :settings, :mailbox_last_error_at, :datetime
  end
end
