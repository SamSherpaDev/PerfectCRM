# One unsent draft per conversation (reply) or per owner (new message).
# Drafts are the only place AI text will appear later; sending never
# auto-fires from here — the captain always presses Send.
class CreateDrafts < ActiveRecord::Migration[8.1]
  def change
    create_table :drafts do |t|
      t.string :owner_type, null: false
      t.integer :owner_id, null: false
      t.references :conversation, foreign_key: true, index: false
      t.text :to_addrs, default: ""
      t.text :cc_addrs, default: ""
      t.text :bcc_addrs, default: ""
      t.string :subject, default: ""
      t.text :body, default: ""
      t.references :template, foreign_key: true
      t.integer :perfectbook_booking_id
      t.timestamps
    end
    add_index :drafts, %i[owner_type owner_id]
    add_index :drafts, :conversation_id, unique: true, where: "conversation_id IS NOT NULL"
  end
end
