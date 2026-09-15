require "test_helper"
require_relative "../support/google_sign_in_test_helper"

class MailImportsRequestsTest < ActionDispatch::IntegrationTest
  include GoogleSignInTestHelper

  setup do
    sign_in
  end

  test "new import renders scope choices without a 90-day cap" do
    get new_mail_import_path
    assert_response :success
    assert_select "select[name='mail_import[scope]']"
    assert_match(/no 90-day cap/i, response.body)
  end

  test "preview stores rows and commit enqueues the job" do
    import = MailImport.create!(scope: "all", status: "draft")
    post preview_mail_import_path(import)
    assert_response :success
    assert_equal "preview", import.reload.status

    assert_enqueued_jobs 1, only: Mail::ImportJob do
      post commit_mail_import_path(import), params: { choices: {} }
    end
    assert_redirected_to mail_import_path(import)
  end

  test "attachment move surfaces the PerfectBook TODO instead of deleting" do
    client = Client.create!(name: "Doc", email: "doc@example.com")
    conversation = Conversation.create!(subject: "Docs", linkable: client, last_message_at: Time.current)
    message = conversation.messages.create!(direction: "in", from_address: "doc@example.com",
      to_addresses: [ "info@sherpaholidays.com" ], subject: "Docs", sent_at: Time.current, text_body: "see attached")
    message.files.attach(io: StringIO.new("file-bytes"), filename: "passport.pdf", content_type: "application/pdf")
    attachment = message.files.attachments.first

    post move_to_perfectbook_attachment_path(attachment)
    assert_redirected_to inbox_thread_path(conversation)
    assert_match(/pb-document-intake/, flash[:alert].to_s)
    assert_equal 1, message.files.attachments.count
  end
end
