class CreateMailMessageQuarantines < ActiveRecord::Migration[8.1]
  def change
    create_table :mail_message_quarantines do |t|
      t.string :provider_message_id, null: false
      t.string :folder
      t.string :error_class, null: false
      t.text :last_error
      t.integer :attempts, default: 0, null: false
      t.datetime :last_failed_at
      t.datetime :quarantined_at
      t.timestamps
      t.index :provider_message_id, unique: true
    end
  end
end
