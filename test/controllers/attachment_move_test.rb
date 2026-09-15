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

    blob = attachment.blob
    assert blob.service.exist?(blob.key)
    get attachment_path(attachment)
    assert_response :success
    assert_equal "file-bytes", response.body
    assert_match(/attachment/, response.headers["Content-Disposition"])

    assert_difference([ "ActivityEvent.count", "Note.count" ], 1) do
      post move_to_perfectbook_attachment_path(attachment)
    end
    assert_redirected_to inbox_thread_path(conversation)
    assert_match(/Removed from CRM/, flash[:notice].to_s)
    assert_equal 0, message.files.attachments.count
    assert_not blob.service.exist?(blob.key)
    get inbox_thread_path(conversation)
    assert_select "p", text: /Collect the sensitive document/
  end
end
