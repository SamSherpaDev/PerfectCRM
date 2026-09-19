require "test_helper"

class ClientMailerTest < ActionMailer::TestCase
  LOGO_BYTES = Base64.decode64(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
  ).freeze

  setup do
    @client = Client.create!(name: "Maya Gurung", email: "maya@example.com")
    Setting.current.update!(sender_name: "Sam", email_signature: "Sam Sherpa", email_signature_html: "")
    @message = Outbound::Composer.call(owner: @client,
      params: { to: "maya@example.com", subject: "Your trek", body: "Hello *Maya*, see _notes_." })
  end

  teardown do
    setting = Setting.current
    setting.signature_logo.purge if setting.signature_logo.attached?
    setting.update!(email_signature: "Sam Sherpa", email_signature_html: "")
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

  test "sender punctuation survives delivery as one mailbox" do
    name = 'Sam, "Sherpa Holidays"'
    Setting.current.update!(sender_name: name)
    delivered = ClientMailer.outbound(@message).deliver_now
    parsed = Mail.read_from_string(delivered.encoded)
    assert_equal [ "info@sherpaholidays.com" ], parsed.from
    assert_equal name, parsed[:from].addrs.first.display_name
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

  test "each part carries the text signature exactly once" do
    mail = ClientMailer.outbound(@message)
    assert_equal 1, mail.text_part.body.to_s.scan("Sam Sherpa").size
    assert_equal 1, mail.html_part.body.to_s.scan("Sam Sherpa").size
  end

  test "HTML signature embeds the logo by Content-ID with no external image" do
    attach_logo
    Setting.current.update!(email_signature_html:
      '<p style="font-size: 12pt; color: #123456">Sam Sherpa</p><img src="https://tracker.example/p.gif">')
    mail = ClientMailer.outbound(@message)
    html = mail.html_part.body.to_s
    assert_includes html, "cid:#{EmailSignature::CID}"
    assert_includes html, "font-size: 12pt"
    assert_not_includes html, "tracker.example"
    assert_not_includes html, "https://"
    inline = mail.attachments.find { |attachment| attachment.filename == "signature-logo.png" }
    assert inline.inline?
    assert_equal "<#{EmailSignature::CID}>", inline.content_id
    assert_includes html, inline.content_id.delete("<>")
    assert_equal 1, html.scan("Sam Sherpa").size
  end

  test "template signature renders the HTML signature at its spot" do
    attach_logo
    template = Template.create!(name: "Signed", purpose: "custom",
      subject: "Hi", body: "Regards {{signature}}\nPS: see you soon")
    rendered = template.rendered("signature" => EmailSignature.text_for(Setting.current))
    message = Outbound::Composer.call(owner: @client,
      params: { to: "maya@example.com", subject: rendered[:subject], body: rendered[:body], template_id: template.id })
    html = ClientMailer.outbound(message).html_part.body.to_s
    assert_equal 1, html.scan("Sam Sherpa").size
    assert_includes html, "cid:#{EmailSignature::CID}"
    assert_match(/Regards.*Sam Sherpa.*PS: see you soon/m, html.gsub(/<[^>]+>/, " "))
  end

  test "template signature is found in a browser-submitted CRLF body" do
    attach_logo
    Setting.current.update!(email_signature: "Sam Sherpa\nSherpa Holidays")
    template = Template.create!(name: "Signed", purpose: "custom",
      subject: "Hi", body: "Regards\n{{signature}}\n\nPS: see you soon")
    rendered = template.rendered("signature" => EmailSignature.text_for(Setting.current))
    message = Outbound::Composer.call(owner: @client,
      params: { to: "maya@example.com", subject: rendered[:subject],
                body: rendered[:body].gsub("\n", "\r\n"), template_id: template.id })
    assert_not_includes message.text_body, "\r"
    mail = ClientMailer.outbound(message)
    html = mail.html_part.body.to_s
    assert_equal 1, html.scan("Sam Sherpa").size
    assert_includes html, "cid:#{EmailSignature::CID}"
    assert_equal 1, mail.attachments.count(&:inline?)
    assert_match(/Regards.*Sam Sherpa.*PS: see you soon/m, html.gsub(/<[^>]+>/, " "))
  end

  test "HTML part mirrors the stored text when the signature changed after compose" do
    attach_logo
    Setting.current.update!(email_signature: "Sam Sherpa\nNew line")
    mail = ClientMailer.outbound(@message)
    html = mail.html_part.body.to_s
    assert_equal 1, html.scan("Sam Sherpa").size
    assert_not_includes html, "New line"
    assert_not_includes html, "cid:#{EmailSignature::CID}"
    assert_empty mail.attachments.select(&:inline?)
  end

  test "pasted scripts never reach the HTML part" do
    Setting.current.update!(email_signature_html: "<p>Sam Sherpa</p><script>alert(1)</script>")
    html = ClientMailer.outbound(@message).html_part.body.to_s
    assert_not_includes html, "<script"
    assert_not_includes html, "alert(1)"
  end

  private

  def attach_logo
    Setting.current.signature_logo.attach(
      io: StringIO.new(LOGO_BYTES), filename: "logo.png", content_type: "image/png"
    )
  end
end
