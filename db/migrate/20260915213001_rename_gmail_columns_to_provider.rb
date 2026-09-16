# Renames the Gmail-specific columns to provider-neutral names. The old
# partial indexes name the column in their WHERE clause, which SQLite
# cannot copy across a rename, so they are dropped first and re-added.
class RenameGmailColumnsToProvider < ActiveRecord::Migration[8.1]
  def up
    remove_index :conversations, name: "index_conversations_on_gm_thread_id"
    rename_column :conversations, :gm_thread_id, :provider_thread_id
    add_index :conversations, :provider_thread_id, unique: true,
      where: "provider_thread_id IS NOT NULL AND provider_thread_id != ''",
      name: "index_conversations_on_provider_thread_id"

    remove_index :messages, name: "index_messages_on_gm_message_id"
    rename_column :messages, :gm_message_id, :provider_message_id
    add_index :messages, :provider_message_id, unique: true,
      where: "provider_message_id IS NOT NULL AND provider_message_id != ''",
      name: "index_messages_on_provider_message_id"

    rename_column :messages, :gmail_labels, :provider_labels
  end

  def down
    rename_column :messages, :provider_labels, :gmail_labels

    remove_index :messages, name: "index_messages_on_provider_message_id"
    rename_column :messages, :provider_message_id, :gm_message_id
    add_index :messages, :gm_message_id, unique: true,
      where: "gm_message_id IS NOT NULL AND gm_message_id != ''",
      name: "index_messages_on_gm_message_id"

    remove_index :conversations, name: "index_conversations_on_provider_thread_id"
    rename_column :conversations, :provider_thread_id, :gm_thread_id
    add_index :conversations, :gm_thread_id, unique: true,
      where: "gm_thread_id IS NOT NULL AND gm_thread_id != ''",
      name: "index_conversations_on_gm_thread_id"
  end
end
