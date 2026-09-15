class CreatePerfectbookSyncStates < ActiveRecord::Migration[8.1]
  def change
    create_table :perfectbook_sync_states do |t|
      t.string :job_name, null: false
      t.datetime :last_success_at
      t.text :last_error
      t.datetime :last_error_at
      t.timestamps
    end
    add_index :perfectbook_sync_states, :job_name, unique: true
  end
end
