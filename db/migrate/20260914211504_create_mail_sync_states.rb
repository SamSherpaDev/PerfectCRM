class CreateMailSyncStates < ActiveRecord::Migration[8.1]
  def change
    create_table :mail_sync_states do |t|
      t.string :folder, null: false
      t.integer :uid_validity
      t.integer :last_uid, default: 0, null: false
      t.datetime :last_sync_at
      t.text :last_error
      t.datetime :last_error_at
      t.timestamps
    end
    add_index :mail_sync_states, :folder, unique: true
  end
end
