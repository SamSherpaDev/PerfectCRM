require "test_helper"
require_relative "../../db/migrate/20260926225100_repair_backfilled_first_paid_at"

class FirstPaidAtRepairMigrationTest < ActiveSupport::TestCase
  test "repairs only older paid rows sharing the earliest paid timestamp" do
    stamp = Time.zone.local(2026, 9, 26, 12)
    rows = [
      [ 5000, stamp, stamp - 3.months ],
      [ 5000, stamp, stamp - 2.months ],
      [ 5000, stamp + 1.day, stamp - 1.month ],
      [ 5000, stamp, stamp ],
      [ 5000, stamp, stamp + 1.day ],
      [ 0, stamp, stamp - 1.month ],
      [ 0, stamp - 1.day, stamp - 1.month ],
      [ 0, nil, stamp - 1.month ]
    ].each_with_index.map do |(paid, first_paid, created), i|
      PerfectBook::Booking.create!(perfectbook_id: i + 1, perfectbook_contact_id: 42,
        paid_minor: paid, first_paid_at: first_paid, created_at: created, synced_at: stamp)
    end
    before = rows.map(&:attributes)

    assert_no_difference "PerfectBook::Booking.count" do
      RepairBackfilledFirstPaidAt.new.migrate(:up)
    end
    rows.each_with_index do |row, i|
      expected = before[i].dup
      expected["first_paid_at"] = expected["created_at"] if i < 2
      assert_equal expected, row.reload.attributes
    end

    repaired = rows.map(&:attributes)
    RepairBackfilledFirstPaidAt.new.migrate(:down)
    assert_equal repaired, rows.map { |row| row.reload.attributes }
  end
end
