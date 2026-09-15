class CreatePerfectbookTrips < ActiveRecord::Migration[8.1]
  def change
    create_table :perfectbook_trips do |t|
      t.integer :perfectbook_id, null: false
      t.string :name, null: false
      t.boolean :active, null: false, default: false
      t.string :status
      t.string :shopify_product_id
      t.integer :departures_count, default: 0
      t.text :departure_ids
      t.date :first_start_date
      t.date :last_end_date
      t.datetime :pb_created_at
      t.datetime :pb_updated_at
      t.datetime :synced_at, null: false
      t.timestamps
    end
    add_index :perfectbook_trips, :perfectbook_id, unique: true
  end
end
