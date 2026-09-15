require "test_helper"

class OutboundComposerTest < ActiveSupport::TestCase
  setup do
    @client = Client.create!(name: "Maya Gurung", email: "maya@example.com")
    Setting.current.update!(sender_name: "Sam", email_signature: "Sam Sherpa")
  end

  test "defaults recipients to the record email and starts a queued message" do
    message = Outbound::Composer.call(owner: @client, params: { body: "Hi Maya" })
    assert message.persisted?
    assert_equal "queued", message.status
    assert_equal "outbound", message.direction
    assert_equal "maya@example.com", message.to_addrs
    assert_equal "Hello from Sherpa Holidays", message.subject
  end

  test "appends the signature once" do
    message = Outbound::Composer.call(owner: @client,
      params: { to: "maya@example.com", subject: "Hi", body: "Hello" })
    assert_equal "Hello\n\nSam Sherpa\n", message.text_body
    again = Outbound::Composer.call(owner: @client,
      params: { to: "maya@example.com", subject: "Hi", body: "Hello\n\nSam Sherpa\n" })
    assert_equal "Hello\n\nSam Sherpa\n", again.text_body
  end

  test "skips the appended signature when the template carries {{signature}}" do
    template = Template.create!(name: "Signed", purpose: "custom",
      subject: "Hi", body: "Hello\n\n{{signature}}")
    message = Outbound::Composer.call(owner: @client,
      params: { to: "maya@example.com", subject: "Hi", body: "Hello\n\nSam Sherpa", template_id: template.id })
    assert_equal "Hello\n\nSam Sherpa", message.text_body
  end

  test "spaced signature placeholders do not append another signature after a postscript" do
    template = Template.create!(name: "Signed with postscript", purpose: "custom",
      subject: "Hi", body: "Regards {{ signature }}\nPS: See you soon")
    rendered = template.rendered("signature" => "Sam Sherpa")
    message = Outbound::Composer.call(owner: @client,
      params: { subject: rendered[:subject], body: rendered[:body], template_id: template.id })
    assert_equal "Regards Sam Sherpa\nPS: See you soon", message.text_body
  end

  test "generates a Message-ID once and threads replies under the parent" do
    first = Outbound::Composer.call(owner: @client,
      params: { to: "maya@example.com", subject: "Your trek", body: "Hello" })
    assert_match(/\A[^@]+@sherpaholidays\.com\z/, first.message_id)
    assert_nil first.in_reply_to

    reply = Outbound::Composer.call(owner: @client, conversation: first.conversation,
      params: { to: "maya@example.com", subject: "", body: "Following up" })
    assert_equal first.message_id, reply.in_reply_to
    assert_includes reply.references.to_s.split, first.message_id
    assert_equal "Re: Your trek", reply.subject
    assert_not_equal first.message_id, reply.message_id
  end

  test "starts a new conversation even with a matching subject" do
    first = Outbound::Composer.call(owner: @client,
      params: { to: "maya@example.com", subject: "Your trek", body: "Hello" })
    second = Outbound::Composer.call(owner: @client,
      params: { to: "maya@example.com", subject: "Your trek", body: "Again" })
    assert_not_equal first.conversation_id, second.conversation_id
  end

  test "records template use and links the template" do
    template = Template.create!(name: "Nudge", purpose: "deposit_nudge", subject: "Hi", body: "Pay")
    message = Outbound::Composer.call(owner: @client,
      params: { to: "maya@example.com", subject: "Hi", body: "Pay", template_id: template.id })
    assert_equal template.id, message.template_id
    assert_equal 1, template.reload.usage_count
  end

  test "rejects sends with no words rather than queuing blanks" do
    assert_raises(ActiveRecord::RecordInvalid) do
      Outbound::Composer.call(owner: @client,
        params: { to: "maya@example.com", subject: "Hi", body: "  " })
    end
  end

  test "attaches uploaded files" do
    tempfile = Tempfile.new([ "hi", ".txt" ])
    tempfile.write("hello")
    tempfile.rewind
    file = ActionDispatch::Http::UploadedFile.new(tempfile: tempfile, filename: "hi.txt", type: "text/plain")
    message = Outbound::Composer.call(owner: @client,
      params: { to: "maya@example.com", subject: "Hi", body: "See attached", files: [ file ] })
    assert_equal [ "hi.txt" ], message.files.map { |file| file.filename.to_s }
  end

  test "group sends without a matching record still queue" do
    group = GroupSend.create!(template: Template.create!(name: "T", purpose: "custom", body: "b"))
    message = Outbound::Composer.call(owner: nil, group_send: group,
      params: { to: "stranger@example.com", subject: "Hi", body: "Hello" })
    assert message.persisted?
    assert_nil message.conversation_id
    assert_equal group.id, message.group_send_id
  end
end
