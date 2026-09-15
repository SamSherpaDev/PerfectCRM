class CreateConversations < ActiveRecord::Migration[8.1]
  def change
    create_table :conversations do |t|
      t.string :subject
      t.string :gm_thread_id
      t.text :participant_emails, default: "[]", null: false
      t.datetime :last_message_at
      t.integer :unread_count, default: 0, null: false
      t.string :linkable_type
      t.integer :linkable_id
      t.boolean :ignored, default: false, null: false
      t.timestamps
    end
    add_index :conversations, :gm_thread_id, unique: true, where: "gm_thread_id IS NOT NULL AND gm_thread_id != ''"
    add_index :conversations, %i[linkable_type linkable_id]
    add_index :conversations, :last_message_at
    add_index :conversations, :ignored
  end
end
