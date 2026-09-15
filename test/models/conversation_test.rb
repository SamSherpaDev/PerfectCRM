require "test_helper"

class ConversationModelTest < ActiveSupport::TestCase
  test "waiting_on_you is true when inbound is newer than the last outbound" do
    conversation = Conversation.create!(subject: "Trip", last_message_at: Time.current)
    conversation.messages.create!(direction: "out", from_address: "info@sherpaholidays.com",
      to_addresses: [ "a@test" ], subject: "Hi", sent_at: 2.days.ago, text_body: "out")
    conversation.messages.create!(direction: "in", from_address: "a@test",
      to_addresses: [ "info@sherpaholidays.com" ], subject: "Re", sent_at: 1.day.ago, text_body: "in")
    assert conversation.reload.waiting_on_you?
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
