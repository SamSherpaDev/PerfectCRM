class CreateMessages < ActiveRecord::Migration[8.1]
  def change
    create_table :messages do |t|
      t.references :conversation, null: false, foreign_key: true
      t.string :direction, null: false, default: "in"
      t.string :gm_message_id
      t.string :message_id
      t.string :in_reply_to
      t.text :references_text
      t.string :from_address
      t.text :to_addresses, default: "[]", null: false
      t.text :cc_addresses, default: "[]", null: false
      t.string :subject
      t.text :text_body
      t.text :html_body
      t.datetime :sent_at
      t.datetime :read_at
      t.integer :raw_size, default: 0, null: false
      t.text :gmail_labels, default: "[]", null: false
      t.timestamps
    end
    add_index :messages, :gm_message_id, unique: true, where: "gm_message_id IS NOT NULL AND gm_message_id != ''"
    add_index :messages, :message_id
    add_index :messages, %i[conversation_id sent_at]
  end
end
