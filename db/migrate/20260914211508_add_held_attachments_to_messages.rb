class AddHeldAttachmentsToMessages < ActiveRecord::Migration[8.1]
  def change
    add_column :messages, :held_attachments, :text, default: "[]", null: false
  end
end
