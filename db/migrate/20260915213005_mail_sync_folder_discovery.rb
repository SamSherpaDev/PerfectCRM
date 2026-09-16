# Two separate facts about a watched folder: that it appeared after the
# mailbox was already syncing, and that the captain has been told about it.
# Inferring both from a missing delta link cannot distinguish a folder that
# is genuinely new from one whose setup merely failed.
class MailSyncFolderDiscovery < ActiveRecord::Migration[8.1]
  def change
    add_column :mail_sync_states, :discovered_at, :datetime
    add_column :mail_sync_states, :announced_at, :datetime
  end
end
