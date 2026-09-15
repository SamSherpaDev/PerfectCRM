class CreateDocumentHoldings < ActiveRecord::Migration[8.1]
  def change
    create_table :document_holdings do |t|
      t.integer :message_id, null: false
      t.string :filename, null: false
      t.string :content_type
      t.integer :byte_size, null: false, default: 0
      t.string :status, null: false, default: "held"
      t.datetime :expires_at, null: false
      t.timestamps
    end
    add_index :document_holdings, :message_id
    add_index :document_holdings, :expires_at
  end
end
