class AddPaymentTermsToPerfectbookBookings < ActiveRecord::Migration[8.1]
  def change
    add_column :perfectbook_bookings, :payment_terms, :json
  end
end
