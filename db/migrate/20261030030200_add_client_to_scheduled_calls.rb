class AddClientToScheduledCalls < ActiveRecord::Migration[8.1]
  def change
    change_column_null :scheduled_calls, :lead_id, true
    add_reference :scheduled_calls, :client, null: true, foreign_key: { on_delete: :cascade }
    add_index :scheduled_calls, [ :client_id, :status, :scheduled_at ]

    reversible do |direction|
      direction.up do
        execute <<~SQL
          UPDATE scheduled_calls
          SET client_id = (
            SELECT converted_client_id
            FROM leads
            WHERE leads.id = scheduled_calls.lead_id
              AND leads.converted_client_id IS NOT NULL
          )
          WHERE lead_id IN (
            SELECT id FROM leads WHERE converted_client_id IS NOT NULL
          )
        SQL
      end
    end
  end
end
