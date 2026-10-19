require "test_helper"

class ScheduledCallTest < ActiveSupport::TestCase
  setup do
    @lead = Lead.create!(name: "Tenzing Sherpa", email: "tenzing@example.com")
    @lead.mark_potential!
  end

  test "parses Pacific scheduled_on and scheduled_time with default 30 minute duration" do
    call = @lead.scheduled_calls.create!(
      scheduled_on: "2026-10-21",
      scheduled_time: "14:30",
      notes: "Everest Base Camp dates"
    )

    assert_equal 30, call.duration_minutes
    assert_equal "scheduled", call.status
    assert_equal Time.zone.local(2026, 10, 21, 14, 30), call.scheduled_at
    assert_equal "2026-10-21", call.scheduled_on
    assert_equal "14:30", call.scheduled_time
  end

  test "rejects blank or malformed date and time strings" do
    blank_call = @lead.scheduled_calls.build(scheduled_on: "", scheduled_time: "")
    assert_not blank_call.valid?
    assert_includes blank_call.errors[:scheduled_at].join(" "), "date and time"

    bad_time = @lead.scheduled_calls.build(scheduled_on: "2026-10-21", scheduled_time: "not-a-time")
    assert_not bad_time.valid?
    assert_includes bad_time.errors[:scheduled_at].join(" "), "valid Pacific date and time"
  end

  test "refuses scheduling on archived or converted leads" do
    archived = Lead.create!(name: "Archived lead")
    archived.archive!
    call = archived.scheduled_calls.build(scheduled_on: "2026-10-21", scheduled_time: "10:00")
    assert_not call.valid?

    converted = Lead.create!(name: "Converted lead", email: "conv@example.com")
    converted.convert_to_client!
    call_on_converted = converted.scheduled_calls.build(scheduled_on: "2026-10-21", scheduled_time: "10:00")
    assert_not call_on_converted.valid?
  end

  test "missed, upcoming, and visible scopes filter accurately" do
    travel_to Time.zone.local(2026, 10, 20, 12, 0) do
      past_call = @lead.scheduled_calls.create!(scheduled_at: 2.hours.ago, notes: "Morning check-in")
      future_call = @lead.scheduled_calls.create!(scheduled_at: 3.hours.from_now, notes: "Afternoon call")

      spam_lead = Lead.create!(name: "Spammer")
      spam_call = spam_lead.scheduled_calls.create!(scheduled_at: 1.hour.from_now)
      spam_lead.mark_as_spam!
      suspected = Lead.create!(name: "Maybe real", tag_list: Lead::SUSPECTED_SPAM_TAG)
      suspected_call = suspected.scheduled_calls.create!(scheduled_at: 4.hours.from_now)

      assert_equal [ past_call ], ScheduledCall.visible.missed.to_a
      assert_equal [ future_call, suspected_call ], ScheduledCall.visible.upcoming.to_a
      assert_not_includes ScheduledCall.visible.to_a, spam_call
      assert past_call.missed?
      assert_not future_call.missed?
    end
  end

  test "complete! logs an ActivityEvent via CallLog and marks the scheduled call completed" do
    call = @lead.scheduled_calls.create!(
      scheduled_on: "2026-10-20",
      scheduled_time: "09:00",
      notes: "Discuss acclimatization days"
    )

    freeze_time do
      event = call.complete!(outcome: "connected", save_key: "complete-call-key-1")
      assert_equal "completed", call.reload.status
      assert_equal "connected", call.outcome
      assert_equal Time.current, call.completed_at
      assert_equal event, call.activity_event
      assert_equal "call", event.kind
      assert_equal "Call: Talked", event.summary
      assert_equal "connected", event.metadata["outcome"]
      assert_nil @lead.reload.next_scheduled_call
    end
  end

  test "reschedule! and cancel! transition status and update Lead#next_scheduled_call" do
    call = @lead.scheduled_calls.create!(scheduled_on: "2026-10-20", scheduled_time: "09:00")
    assert_equal call, @lead.next_scheduled_call

    call.reschedule!(scheduled_on: "2026-10-22", scheduled_time: "16:00", duration_minutes: 45, notes: "Moved to Thursday")
    assert_equal Time.zone.local(2026, 10, 22, 16, 0), call.reload.scheduled_at
    assert_equal 45, call.duration_minutes
    assert_equal "Moved to Thursday", call.notes
    assert_equal "scheduled", call.status

    call.cancel!
    assert_equal "cancelled", call.reload.status
    assert_not_nil call.cancelled_at
    assert_nil @lead.reload.next_scheduled_call
  end

  test "closed calls cannot be completed, cancelled, or rescheduled" do
    call = @lead.scheduled_calls.create!(scheduled_on: "2026-10-20", scheduled_time: "09:00")
    call.cancel!

    assert_raises(ActiveRecord::RecordInvalid) { call.complete!(outcome: "connected", save_key: "closed-call-key-1") }
    assert_raises(ActiveRecord::RecordInvalid) { call.reschedule!(scheduled_on: "2026-10-22", scheduled_time: "16:00") }
    assert_equal 0, @lead.activity_events.where(kind: "call").count

    completed = @lead.scheduled_calls.create!(scheduled_on: "2026-10-21", scheduled_time: "09:00")
    completed.complete!(outcome: "connected", save_key: "closed-call-key-2")
    assert_raises(ActiveRecord::RecordInvalid) { completed.cancel! }
    assert_equal "completed", completed.reload.status
  end
end
