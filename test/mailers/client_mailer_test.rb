require "test_helper"

class ClientMailerTest < ActionMailer::TestCase
  setup do
    @client = Client.create!(name: "Maya Gurung", email: "maya@example.com")
    Setting.current.update!(sender_name: "Sam", email_signature: "Sam Sherpa")
    @message = Outbound::Composer.call(owner: @client,
      params: { to: "maya@example.com", subject: "Your trek", body: "Hello *Maya*, see _notes_." })
  end

  test "sends as the mailbox with threading headers without internal identifiers" do
    mail = ClientMailer.outbound(@message)
    assert_equal [ "maya@example.com" ], mail.to
    assert_equal "Sam <info@sherpaholidays.com>", mail[:from].value
    assert_equal "info@sherpaholidays.com", mail[:reply_to].value
    assert_equal "Your trek", mail.subject
    assert_equal @message.message_id, mail.header["Message-ID"].value
    assert_nil mail.header["X-PerfectCRM-Client"]
    assert_includes mail.text_part.body.to_s, "Hello *Maya*"
    assert_includes mail.html_part.body.to_s, "*Maya*"
    assert_includes mail.html_part.body.to_s, "_notes_"
  end

  test "carries In-Reply-To and References on replies" do
    reply = Outbound::Composer.call(owner: @client, conversation: @message.conversation,
      params: { to: "maya@example.com", subject: "", body: "Following up" })
    mail = ClientMailer.outbound(reply)
    assert_equal @message.message_id, mail.header["In-Reply-To"].value
    assert_includes mail.header["References"].value, @message.message_id
  end

  test "plain text escapes HTML and preserves line breaks" do
    @message.update!(text_body: "<script>alert(1)</script>\n*literal*\n\nNext")
    html = ClientMailer.outbound(@message).html_part.body.to_s
    assert_includes html, "&lt;script&gt;alert(1)&lt;/script&gt;<br>*literal*"
    assert_includes html, "<p>Next</p>"
  end

  test "attaches uploaded files" do
    @message.files.attach(io: StringIO.new("hello"), filename: "hi.txt", content_type: "text/plain")
    mail = ClientMailer.outbound(@message.reload)
    assert_equal [ "hi.txt" ], mail.attachments.map(&:filename)
  end
end
