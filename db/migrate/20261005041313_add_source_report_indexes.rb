class AddSourceReportIndexes < ActiveRecord::Migration[8.1]
  def change
    add_index :perfectbook_bookings, :first_received_at
    add_index :perfectbook_bookings, :first_received_on
    add_index :perfectbook_bookings, :cancelled_at
    add_index :perfectbook_bookings, [ :perfectbook_contact_id, :first_received_at ], name: "index_bookings_contact_receipt"
  end
end
