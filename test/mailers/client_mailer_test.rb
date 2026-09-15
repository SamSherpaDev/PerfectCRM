require "test_helper"

class ClientMailerTest < ActionMailer::TestCase
  setup do
    @client = Client.create!(name: "Maya Gurung", email: "maya@example.com")
    Setting.current.update!(sender_name: "Sam", email_signature: "Sam Sherpa")
    @message = Outbound::Composer.call(owner: @client,
      params: { to: "maya@example.com", subject: "Your trek", body: "Hello *Maya*, see _notes_." })
  end

  test "sends as the mailbox with threading headers and the client mark" do
    mail = ClientMailer.outbound(@message)
    assert_equal [ "maya@example.com" ], mail.to
    assert_equal "Sam <info@sherpaholidays.com>", mail[:from].value
    assert_equal "info@sherpaholidays.com", mail[:reply_to].value
    assert_equal "Your trek", mail.subject
    assert_equal @message.message_id, mail.header["Message-ID"].value
    assert_equal "Client:#{@client.id}", mail.header["X-PerfectCRM-Client"].value
    assert_includes mail.text_part.body.to_s, "Hello *Maya*"
    assert_includes mail.html_part.body.to_s, "<strong>Maya</strong>"
    assert_includes mail.html_part.body.to_s, "<em>notes</em>"
  end

  test "carries In-Reply-To and References on replies" do
    reply = Outbound::Composer.call(owner: @client, conversation: @message.conversation,
      params: { to: "maya@example.com", subject: "", body: "Following up" })
    mail = ClientMailer.outbound(reply)
    assert_equal @message.message_id, mail.header["In-Reply-To"].value
    assert_includes mail.header["References"].value, @message.message_id
  end

  test "attaches uploaded files" do
    @message.files.attach(io: StringIO.new("hello"), filename: "hi.txt", content_type: "text/plain")
    mail = ClientMailer.outbound(@message.reload)
    assert_equal [ "hi.txt" ], mail.attachments.map(&:filename)
  end
end
