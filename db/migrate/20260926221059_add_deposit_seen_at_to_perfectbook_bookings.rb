class AddDepositSeenAtToPerfectbookBookings < ActiveRecord::Migration[8.1]
  def up
    add_column :perfectbook_bookings, :deposit_seen_at, :datetime
    # Bookings already paid count from their first mirror sync, so the first
    # weekly report does not list them as this week's deposits.
    execute "UPDATE perfectbook_bookings SET deposit_seen_at = created_at WHERE paid_minor > 0"
  end

  def down
    remove_column :perfectbook_bookings, :deposit_seen_at
  end
end
