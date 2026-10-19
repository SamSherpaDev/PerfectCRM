class CreateScheduledCalls < ActiveRecord::Migration[8.1]
  def change
    create_table :scheduled_calls do |t|
      t.references :lead, null: false, foreign_key: { on_delete: :cascade }
      t.datetime :scheduled_at, null: false
      t.integer :duration_minutes, null: false, default: 30
      t.text :notes
      t.string :status, null: false, default: "scheduled"
      t.string :outcome
      t.datetime :completed_at
      t.datetime :cancelled_at
      t.references :activity_event, foreign_key: { on_delete: :nullify }

      t.timestamps
    end

    add_index :scheduled_calls, [ :status, :scheduled_at ]
    add_index :scheduled_calls, [ :lead_id, :status, :scheduled_at ]
  end
end
