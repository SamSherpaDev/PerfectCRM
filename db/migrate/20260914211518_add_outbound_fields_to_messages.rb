class AddOutboundFieldsToMessages < ActiveRecord::Migration[8.1]
  def change
    add_reference :messages, :group_send, foreign_key: true
    add_reference :messages, :template, foreign_key: true
    add_column :messages, :status, :string, null: false, default: "received"
    add_column :messages, :bcc_addrs, :text, default: ""
    add_column :messages, :send_error, :text
    add_index :messages, :status
    reversible do |dir|
      dir.up { execute "UPDATE messages SET status = 'sent' WHERE direction = 'out'" }
    end
  end
end
