require "test_helper"

class TasksAutomaticTest < ActiveSupport::TestCase
  setup do
    @client = Client.create!(name: "Maya", email: "maya@example.com", perfectbook_contact_id: 11)
  end

  def mirror(attrs)
    defaults = { perfectbook_id: 100, perfectbook_contact_id: 11, synced_at: Time.current }
    PerfectBook::Booking.create!(defaults.merge(attrs))
  end

  test "review ask fires three days after the departure ends" do
    travel_to Time.zone.parse("2026-09-14 09:00") do
      mirror(end_date: Date.new(2026, 9, 11), trip_name: "Everest", ref: "SH-1")
      assert_difference -> { Task.count }, 1 do
        Tasks::Automatic.run!
      end
      task = Task.last
      assert_equal "review_ask", task.kind
      assert_equal "automation", task.created_by
      assert_equal Date.new(2026, 9, 14), task.due_on
      assert_equal @client, task.subject
    end
  end

  test "repeat nudge fires ten months after return" do
    travel_to Time.zone.parse("2026-09-14 09:00") do
      mirror(perfectbook_id: 101, end_date: Date.new(2025, 11, 14), trip_name: "Annapurna")
      Tasks::Automatic.run!
      task = Task.find_by!(idempotency_key: "repeat-nudge:101")
      assert_equal "follow_up", task.kind
      assert_equal Date.new(2026, 9, 14), task.due_on
    end
  end

  test "deposit nudge fires for a sent invoice unpaid for five days" do
    travel_to Time.zone.parse("2026-09-14 09:00") do
      booking = mirror(perfectbook_id: 102, invoice_badge: "sent", invoice_number: "SH-2026-007",
        balance_due_minor: 50_000, start_date: Date.new(2026, 10, 20))
      booking.update_columns(created_at: 6.days.ago)
      Tasks::Automatic.run!
      task = Task.find_by!(idempotency_key: "deposit-nudge:102:SH-2026-007")
      assert_equal "payment_nudge", task.kind
    end
  end

  test "deposit nudge waits when the invoice is fresh, draft, paid, or past" do
    travel_to Time.zone.parse("2026-09-14 09:00") do
      fresh = mirror(perfectbook_id: 103, invoice_badge: "sent", invoice_number: "SH-1",
        balance_due_minor: 10_000, start_date: Date.new(2026, 12, 1))
      assert_no_difference -> { Task.count } do
        Tasks::Automatic.try_deposit_nudge!(fresh, @client, Date.current)
      end
      draft = mirror(perfectbook_id: 104, invoice_badge: "draft", invoice_number: "SH-2",
        balance_due_minor: 10_000, start_date: Date.new(2026, 12, 1))
      draft.update_columns(created_at: 9.days.ago)
      paid = mirror(perfectbook_id: 105, invoice_badge: "paid", invoice_number: "SH-3",
        balance_due_minor: 0, start_date: Date.new(2026, 12, 1))
      paid.update_columns(created_at: 9.days.ago)
      started = mirror(perfectbook_id: 106, invoice_badge: "sent", invoice_number: "SH-4",
        balance_due_minor: 10_000, start_date: Date.new(2026, 9, 1))
      started.update_columns(created_at: 9.days.ago)
      assert_no_difference -> { Task.count } do
        [ draft, paid, started ].each do |booking|
          Tasks::Automatic.try_deposit_nudge!(booking, @client, Date.current)
        end
      end
    end
  end

  test "each rule fires once per booking no matter how often the job runs" do
    travel_to Time.zone.parse("2026-09-14 09:00") do
      mirror(end_date: Date.new(2026, 9, 11), trip_name: "Everest")
      assert_difference -> { Task.count }, 1 do
        Tasks::Automatic.run!
      end
      assert_no_difference -> { Task.count } do
        Tasks::Automatic.run!
        Tasks::GenerateAutomaticJob.perform_now
      end
    end
  end

  test "bookings with no local record are skipped" do
    travel_to Time.zone.parse("2026-09-14 09:00") do
      mirror(perfectbook_id: 107, perfectbook_contact_id: 999, end_date: Date.new(2026, 9, 11))
      assert_no_difference -> { Task.count } do
        Tasks::Automatic.run!
      end
    end
  end

  test "stage change hook proposes nothing until the pipeline maps a stage" do
    assert_nil Tasks::OnStageChange.call(subject: @client, from: "new", to: "quoted")
    assert_no_difference -> { Task.count } do
      Tasks::OnStageChange.call(subject: @client, from: "new", to: "quoted")
    end
  end
end
