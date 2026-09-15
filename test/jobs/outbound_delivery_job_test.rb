require "test_helper"

class OutboundDeliveryJobTest < ActiveJob::TestCase
  setup do
    @client = Client.create!(name: "Maya Gurung", email: "maya@example.com")
    ActionMailer::Base.deliveries.clear
  end

  test "delivers, marks sent, and clears the draft" do
    conversation = @client.conversations.create!(subject_line: "Hi")
    draft = conversation.create_draft!(owner: @client, body: "words")
    message = Outbound::Composer.call(owner: @client, conversation: conversation,
      params: { to: "maya@example.com", subject: "Hi", body: "Hello" })
    OutboundDeliveryJob.perform_now(message.id)
    assert message.reload.sent?
    assert_not_nil message.sent_at
    assert_equal 1, ActionMailer::Base.deliveries.size
    assert_not Draft.exists?(draft.id)
  end

  test "a hard failure marks the message failed and keeps the draft" do
    conversation = @client.conversations.create!(subject_line: "Hi")
    draft = conversation.create_draft!(owner: @client, body: "keep me")
    message = Outbound::Composer.call(owner: @client, conversation: conversation,
      params: { to: "maya@example.com", subject: "Hi", body: "Hello" })
    ClientMailer.stub(:outbound, ->(*) { raise ArgumentError, "bad address" }) do
      OutboundDeliveryJob.perform_now(message.id)
    end
    assert message.reload.failed?
    assert_equal "bad address", message.send_error
    assert Draft.exists?(draft.id)
    assert_empty ActionMailer::Base.deliveries
  end

  test "a transient failure re-queues, then fails after the last attempt" do
    message = Outbound::Composer.call(owner: @client,
      params: { to: "maya@example.com", subject: "Hi", body: "Hello" })
    ClientMailer.stub(:outbound, ->(*) { raise Net::SMTPServerBusy, "try later" }) do
      perform_enqueued_jobs do
        OutboundDeliveryJob.perform_later(message.id)
      end
    end
    message.reload
    assert message.failed?
    assert_equal "try later", message.send_error
    assert_empty ActionMailer::Base.deliveries
  end
end
