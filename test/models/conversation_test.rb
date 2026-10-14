require "test_helper"

class ConversationModelTest < ActiveSupport::TestCase
  test "automatic email leaves an inquiry waiting until a personal reply or logged call" do
    lead = Lead.create!(name: "Waiting inquiry")
    conversation = Conversation.create!(linkable: lead, subject: "Trip")
    inbound = conversation.messages.create!(direction: "in", status: "received",
      subject: "Trip", text_body: "Hello", sent_at: 2.days.ago)
    automatic = conversation.messages.create!(direction: "out", status: "sent",
      subject: "Trip", to_addrs: "demo@example.com", text_body: "Welcome", sent_at: 2.days.ago + 1.minute)
    AutomaticFirstReply.create!(lead: lead, message: automatic, email: "demo@example.com")
    assert conversation.waiting_on_you?
    assert_includes Conversation.waiting_on_you, conversation
    assert_includes Today::Summary.new.replies_waiting, conversation

    CallLog.record!(lead, key: "demo-call-1", occurred_at: 1.day.ago, outcome: "voicemail", direction: "outbound")
    assert_not conversation.waiting_on_you?
    assert_not_includes Today::Summary.new.replies_waiting, conversation

    inbound.update!(sent_at: 1.hour.ago)
    assert conversation.waiting_on_you?, "new inbound after a call needs a response"
    personal = conversation.messages.create!(direction: "out", status: "failed",
      subject: "Trip", to_addrs: "demo@example.com", text_body: "Let's talk", sent_at: Time.current)
    assert conversation.waiting_on_you?, "a failed personal email does not resolve waiting"
    personal.update!(status: "sent")
    assert_not conversation.waiting_on_you?
    assert_not_includes Conversation.waiting_on_you, conversation
  end

  test "waiting_on_you is true when inbound is newer than the last outbound" do
    conversation = Conversation.create!(subject: "Trip", last_message_at: Time.current)
    conversation.messages.create!(direction: "out", from_address: "info@sherpaholidays.com",
      to_addresses: [ "a@test" ], subject: "Hi", sent_at: 2.days.ago, text_body: "out")
    conversation.messages.create!(direction: "in", from_address: "a@test",
      to_addresses: [ "info@sherpaholidays.com" ], subject: "Re", sent_at: 1.day.ago, text_body: "in")
    assert conversation.reload.waiting_on_you?
  end

  test "a call only clears its inquiry and inbound at the same time still waits" do
    lead = Lead.create!(name: "Waiting")
    other = Lead.create!(name: "Other")
    thread = Conversation.create!(linkable: lead, subject: "Trip")
    at = 1.day.ago.change(usec: 0)
    thread.messages.create!(direction: "in", status: "received", text_body: "Hello", sent_at: at)
    CallLog.record!(other, key: "other-call-1", occurred_at: Time.current, outcome: "connected", direction: "outbound")
    CallLog.record!(lead, key: "earlier-call", occurred_at: at - 1.hour, outcome: "attempted", direction: "outbound")
    CallLog.record!(lead, key: "same-time-call", occurred_at: at, outcome: "connected", direction: "inbound")
    assert thread.waiting_on_you?
    assert_includes Conversation.waiting_on_you, thread

    reply = thread.messages.create!(direction: "out", status: "sent", subject: "Trip",
      to_addrs: "demo@example.com", text_body: "Hello", sent_at: at)
    assert thread.waiting_on_you?, "equal timestamps remain waiting in both interfaces"
    reply.update!(sent_at: at + 1.second)
    assert_not thread.waiting_on_you?
  end

  test "waiting_on_you is false after we reply last" do
    conversation = Conversation.create!(subject: "Trip", last_message_at: Time.current)
    conversation.messages.create!(direction: "in", from_address: "a@test",
      to_addresses: [ "info@sherpaholidays.com" ], subject: "Hi", sent_at: 2.days.ago, text_body: "in")
    conversation.messages.create!(direction: "out", from_address: "info@sherpaholidays.com",
      to_addresses: [ "a@test" ], subject: "Re", sent_at: 1.day.ago, text_body: "out")
    assert_not conversation.reload.waiting_on_you?
  end

  test "mark_read clears the unread count" do
    conversation = Conversation.create!(subject: "Trip", last_message_at: Time.current)
    conversation.messages.create!(direction: "in", from_address: "a@test",
      to_addresses: [ "info@sherpaholidays.com" ], subject: "Hi", sent_at: Time.current, text_body: "in")
    assert_equal 1, conversation.reload.unread_count
    conversation.mark_read!
    assert_equal 0, conversation.reload.unread_count
  end
end
