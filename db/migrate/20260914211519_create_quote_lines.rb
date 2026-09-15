class CreateQuoteLines < ActiveRecord::Migration[8.1]
  def change
    create_table :quote_lines do |t|
      t.references :quote, null: false, foreign_key: true
      t.string :kind, null: false, default: "custom"
      t.string :description, null: false
      t.integer :position, null: false, default: 0
      t.integer :quantity, null: false, default: 1
      t.integer :unit_minor, null: false, default: 0
      t.integer :total_minor, null: false, default: 0
      t.integer :perfectbook_trip_id
      t.integer :perfectbook_departure_id
      t.string :snapshot_trip_name
      t.string :snapshot_departure_label
      t.date :snapshot_start_on
      t.date :snapshot_end_on
      t.timestamps
    end
  end
end
