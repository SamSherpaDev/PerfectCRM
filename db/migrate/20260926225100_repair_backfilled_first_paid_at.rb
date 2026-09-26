class RepairBackfilledFirstPaidAt < ActiveRecord::Migration[8.1]
  def up
    execute <<~SQL
      UPDATE perfectbook_bookings
      SET first_paid_at = created_at
      WHERE paid_minor > 0
        AND first_paid_at = (
          SELECT MIN(first_paid_at) FROM perfectbook_bookings WHERE paid_minor > 0
        )
        AND created_at < first_paid_at
    SQL
  end

  def down
  end
end
