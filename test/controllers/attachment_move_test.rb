require "test_helper"
require_relative "../support/google_sign_in_test_helper"

class AttachmentMoveTest < ActionDispatch::IntegrationTest
  include GoogleSignInTestHelper

  setup do
    sign_in
  end

  test "successful move deletes the file and records an activity event" do
    client = Client.create!(name: "Doc2", email: "doc2@example.com")
    conversation = Conversation.create!(subject: "Docs", linkable: client, last_message_at: Time.current)
    message = conversation.messages.create!(direction: "in", from_address: "doc2@example.com",
      to_addresses: [ "info@sherpaholidays.com" ], subject: "Docs", sent_at: Time.current, text_body: "see attached")
    message.files.attach(io: StringIO.new("file-bytes"), filename: "visa.pdf", content_type: "application/pdf")
    attachment = message.files.attachments.first

    PerfectBook::DocumentUploader.stub(:upload, true) do
      assert_difference("ActivityEvent.count", 1) do
        post move_to_perfectbook_attachment_path(attachment), params: { booking_id: "11" }
      end
    end
    assert_redirected_to inbox_thread_path(conversation)
    assert_match(/Moved/, flash[:notice].to_s)
    assert_equal 0, message.files.attachments.count
  end
end
