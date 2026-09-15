class CreatePerfectbookBookings < ActiveRecord::Migration[8.1]
  def change
    create_table :perfectbook_bookings do |t|
      t.integer :perfectbook_id, null: false
      t.integer :perfectbook_contact_id, null: false
      t.string :ref
      t.string :status
      t.integer :trip_id
      t.string :trip_name
      t.integer :departure_id
      t.string :departure_place
      t.date :start_date
      t.date :end_date
      t.integer :party_size
      t.integer :price_per_person_minor
      t.integer :total_minor
      t.integer :paid_minor
      t.integer :balance_due_minor
      t.string :currency, default: "USD"
      t.string :invoice_badge
      t.string :invoice_number
      t.string :payment_reference
      t.string :deep_link
      t.datetime :synced_at, null: false
      t.timestamps
    end
    add_index :perfectbook_bookings, :perfectbook_id, unique: true
    add_index :perfectbook_bookings, :perfectbook_contact_id
  end
end
