class CreateMailMessageQuarantines < ActiveRecord::Migration[8.1]
  def change
    create_table :mail_message_quarantines do |t|
      t.string :provider_message_id, null: false
      t.integer :attempts, default: 0, null: false
      t.timestamps
      t.index :provider_message_id, unique: true
    end
  end
end
