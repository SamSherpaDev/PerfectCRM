# A group send for a departure: one template rendered per recipient and
# sent as individual emails. Each delivery becomes its own Message
# (logged on its own timeline); this row is the per-batch summary.
class CreateGroupSends < ActiveRecord::Migration[8.1]
  def change
    create_table :group_sends do |t|
      t.references :template, null: false, foreign_key: true
      t.integer :perfectbook_departure_id
      t.string :status, null: false, default: "sending"
      t.integer :total_count, null: false, default: 0
      t.text :recipient_lines
      t.timestamps
    end
    add_index :group_sends, :status
  end
end
