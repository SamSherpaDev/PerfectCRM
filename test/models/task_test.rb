require "test_helper"

class TaskTest < ActiveSupport::TestCase
  setup do
    @client = Client.create!(name: "Maya", email: "maya@example.com")
  end

  test "requires title, due date, kind, and a known subject type" do
    task = Task.new(subject: @client)
    assert_not task.valid?
    assert_includes task.errors[:title], "can't be blank"
    assert_includes task.errors[:due_on], "can't be blank"

    task.title = "Nudge"
    task.due_on = Date.current
    assert task.valid?

    task.kind = "sms"
    assert_not task.valid?
    task.kind = "follow_up"
    assert task.valid?
    assert_equal %w[Client Lead Organization], Task::SUBJECT_TYPES
  end

  test "overdue, today, and upcoming split on the Pacific date" do
    travel_to Time.zone.parse("2026-09-14 09:00") do
      overdue = @client.tasks.create!(title: "Old", due_on: Date.new(2026, 9, 13))
      today = @client.tasks.create!(title: "Now", due_on: Date.new(2026, 9, 14))
      soon = @client.tasks.create!(title: "Soon", due_on: Date.new(2026, 9, 20))
      later = @client.tasks.create!(title: "Later", due_on: Date.new(2026, 9, 22))

      assert_includes Task.overdue, overdue
      assert_not_includes Task.overdue, today
      assert_includes Task.due_today, today
      assert_includes Task.upcoming, soon
      assert_not_includes Task.upcoming, later
      assert_includes Task.due_within_week, overdue
      assert_includes Task.due_within_week, today
      assert_includes Task.due_within_week, soon
      assert overdue.overdue?
      assert_not today.overdue?
    end
  end

  test "a task due yesterday Pacific is overdue just after midnight" do
    travel_to Time.zone.parse("2026-09-15 00:05") do
      task = @client.tasks.create!(title: "Edge", due_on: Date.new(2026, 9, 14))
      assert task.overdue?
      assert_includes Task.overdue, task
    end
  end

  test "snoozed tasks hide until their day arrives" do
    travel_to Time.zone.parse("2026-09-14 09:00") do
      task = @client.tasks.create!(title: "Later", due_on: Date.new(2026, 9, 10))
      task.snooze!("tomorrow")
      assert task.snoozed?
      assert_not_includes Task.visible, task
      assert_not_includes Task.overdue, task

      travel 1.day
      assert_not task.reload.snoozed?
      assert_includes Task.overdue, task
    end
  end

  test "snooze presets and pick-a-date" do
    travel_to Time.zone.parse("2026-09-14 09:00") do
      task = @client.tasks.create!(title: "S", due_on: Date.current)
      assert task.snooze!("tomorrow")
      assert_equal Date.new(2026, 9, 15), task.snoozed_until
      assert task.snooze!("3days")
      assert_equal Date.new(2026, 9, 17), task.snoozed_until
      assert task.snooze!("week")
      assert_equal Date.new(2026, 9, 21), task.snoozed_until
      assert task.snooze!("pick", date: Date.new(2026, 10, 1))
      assert_equal Date.new(2026, 10, 1), task.snoozed_until
      assert_not task.snooze!("pick")
    end
  end

  test "completing records an activity event on the subject timeline" do
    task = @client.tasks.create!(title: "Nudge Maya", kind: "payment_nudge", due_on: Date.current)
    assert_difference -> { @client.activity_events.count }, 1 do
      assert task.complete!
    end
    assert task.done?
    event = @client.activity_events.order(:id).last
    assert_equal "task", event.kind
    assert_equal "Completed: Nudge Maya", event.summary
    assert_not_includes Task.visible, task
    assert_includes Task.done, task
    assert_not task.complete!
  end

  test "belongs to leads and organizations too" do
    lead = Lead.create!(name: "Ask", source: "email")
    org = Organization.create!(name: "Ops Co", kind: "operator")
    assert Task.create!(subject: lead, title: "L", due_on: Date.current).persisted?
    assert Task.create!(subject: org, title: "O", due_on: Date.current).persisted?
  end
end
