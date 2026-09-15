require "test_helper"

class MessageTest < ActiveSupport::TestCase
  setup do
    @client = Client.create!(name: "Maya Gurung", email: "maya@example.com")
    @conversation = @client.conversations.create!(subject_line: "Your trek")
  end

  test "outbound messages require recipients, subject, and body" do
    message = @conversation.messages.build(direction: "outbound", status: "queued")
    assert_not message.valid?
    assert_includes message.errors[:to_addrs], "can't be blank"
    assert_includes message.errors[:subject], "can't be blank"
    assert_includes message.errors[:text_body], "can't be blank"
  end

  test "a message needs a conversation or a group send" do
    message = Message.new(direction: "outbound", status: "queued",
      to_addrs: "a@example.com", subject: "Hi", text_body: "Hello")
    assert_not message.valid?
    assert_includes message.errors[:conversation], "or group send must be present"
  end

  test "mark_sent stamps, touches the thread, and preserves unrelated drafts" do
    draft = @conversation.create_draft!(owner: @client, body: "words")
    message = @conversation.messages.create!(direction: "outbound", status: "sending",
      to_addrs: "maya@example.com", subject: "Hi", text_body: "Hello")
    message.mark_sent!
    assert message.sent?
    assert_not_nil message.sent_at
    assert Draft.exists?(draft.id)
    assert_not_nil @conversation.reload.last_message_at
  end

  test "mark_failed keeps the words and the reason" do
    message = @conversation.messages.create!(direction: "outbound", status: "sending",
      to_addrs: "maya@example.com", subject: "Hi", text_body: "Hello")
    message.mark_failed!("Connection refused")
    assert message.failed?
    assert_equal "Connection refused", message.send_error
    assert_equal "Hello", message.reload.text_body
  end
end

class ConversationTest < ActiveSupport::TestCase
  setup do
    @client = Client.create!(name: "Maya Gurung", email: "maya@example.com")
  end

  test "latest_for returns the most recently active thread" do
    old = @client.conversations.create!(subject_line: "Old", last_message_at: 2.days.ago)
    fresh = @client.conversations.create!(subject_line: "New", last_message_at: 1.hour.ago)
    assert_equal fresh, Conversation.latest_for(@client)
    assert_not_equal old, Conversation.latest_for(@client)
  end

  test "thread_parent is the newest message with an id" do
    conversation = @client.conversations.create!(subject_line: "T")
    first = conversation.messages.create!(direction: "outbound", status: "sent",
      to_addrs: "m@example.com", subject: "Hi", text_body: "one", message_id: "<one@x>")
    conversation.messages.create!(direction: "outbound", status: "sent",
      to_addrs: "m@example.com", subject: "Hi", text_body: "two", message_id: "<two@x>")
    assert_equal "<two@x>", conversation.thread_parent.message_id
    assert_equal 2, conversation.messages.count
    assert_equal first.message_id, "<one@x>"
  end
end

class DraftTest < ActiveSupport::TestCase
  setup do
    @client = Client.create!(name: "Maya Gurung", email: "maya@example.com")
  end

  test "for_owner finds the conversation draft or builds one" do
    conversation = @client.conversations.create!(subject_line: "T")
    draft = Draft.for_owner(@client, conversation: conversation)
    assert draft.new_record?
    draft.update!(body: "words")
    assert_equal draft, Draft.for_owner(@client, conversation: conversation)
  end

  test "for_owner without a conversation keeps a separate owner draft" do
    draft = Draft.for_owner(@client)
    assert draft.new_record?
    assert_nil draft.conversation
  end

  test "empty drafts carry nothing worth keeping" do
    assert Draft.new(owner: @client).empty?
    assert_not Draft.new(owner: @client, body: "words").empty?
  end
end

class GroupSendTest < ActiveSupport::TestCase
  setup do
    @template = Template.create!(name: "Group", purpose: "custom", subject: "Hi", body: "Hello")
  end

  test "counts flow from its messages" do
    group = GroupSend.create!(template: @template, total_count: 3)
    conversation = Client.create!(name: "A B", email: "a@example.com").conversations.create!
    group.messages.create!(conversation: conversation, direction: "outbound", status: "sent",
      to_addrs: "a@example.com", subject: "Hi", text_body: "Hello")
    group.messages.create!(conversation: conversation, direction: "outbound", status: "failed",
      to_addrs: "b@example.com", subject: "Hi", text_body: "Hello")
    group.messages.create!(conversation: conversation, direction: "outbound", status: "queued",
      to_addrs: "c@example.com", subject: "Hi", text_body: "Hello")
    assert_equal 1, group.sent_count
    assert_equal 1, group.failed_count
    assert_equal 1, group.pending_count
    group.refresh_status!
    assert_equal "sending", group.status
  end
end
