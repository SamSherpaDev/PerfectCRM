class CreatePerfectbookDepartures < ActiveRecord::Migration[8.1]
  def change
    create_table :perfectbook_departures do |t|
      t.integer :perfectbook_id, null: false
      t.integer :perfectbook_trip_id
      t.string :trip_name
      t.string :label
      t.date :start_date
      t.date :end_date
      t.integer :duration_days
      t.string :place
      t.text :country_codes
      t.string :status
      t.integer :seats
      t.integer :booked_seats
      t.integer :available_seats
      t.integer :price_per_person_minor
      t.string :currency, default: "USD"
      t.datetime :pb_created_at
      t.datetime :pb_updated_at
      t.datetime :synced_at, null: false
      t.timestamps
    end
    add_index :perfectbook_departures, :perfectbook_id, unique: true
    add_index :perfectbook_departures, :perfectbook_trip_id
  end
end
