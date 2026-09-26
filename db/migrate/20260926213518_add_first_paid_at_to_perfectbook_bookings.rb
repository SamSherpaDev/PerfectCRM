class AddFirstPaidAtToPerfectbookBookings < ActiveRecord::Migration[8.1]
  def change
    add_column :perfectbook_bookings, :first_paid_at, :datetime
    reversible do |direction|
      direction.up do
        execute "UPDATE perfectbook_bookings SET first_paid_at = CURRENT_TIMESTAMP WHERE paid_minor > 0"
      end
    end
  end
end
