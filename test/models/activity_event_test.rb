require "test_helper"

class ActivityEventTest < ActiveSupport::TestCase
  test "events order newest first and touch the subject" do
    client = Client.create!(name: "Tashi")
    old = ActivityEvent.create!(subject: client, kind: "email", summary: "Old", occurred_at: 2.days.ago)
    fresh = ActivityEvent.create!(subject: client, kind: "note", summary: "Fresh", occurred_at: Time.current)
    assert_equal [ fresh, old ], client.activity_events.newest_first.to_a
    assert_not_nil client.reload.last_activity_at
  end

  test "events are append-only" do
    client = Client.create!(name: "Tashi")
    event = ActivityEvent.create!(subject: client, kind: "note", summary: "Hi", occurred_at: Time.current)
    assert event.readonly?
    assert_raises(ActiveRecord::ReadOnlyRecord) { event.update!(summary: "Edited") }
  end

  test "metadata round-trips as json" do
    client = Client.create!(name: "Tashi")
    event = ActivityEvent.create!(
      subject: client, kind: "email", summary: "Sent",
      occurred_at: Time.current, metadata: { "message_id" => "<abc>" }
    )
    assert_equal "<abc>", event.reload.metadata["message_id"]
  end
end
