require "test_helper"

def mail_raw(from:, to: "info@sherpaholidays.com", subject: "Hello", message_id: nil, in_reply_to: nil, body: "Hi there")
  headers = []
  headers << "From: #{from}"
  headers << "To: #{to}"
  headers << "Subject: #{subject}"
  headers << "Message-ID: #{message_id}" if message_id
  headers << "In-Reply-To: #{in_reply_to}" if in_reply_to
  headers << "Date: Mon, 14 Sep 2026 10:00:00 -0700"
  headers << ""
  headers << body
  headers.join("\r\n")
end

def ingest_raw(raw, gmail: {})
  parsed = Mail::Ingester.parse_raw(raw)
  Mail::Ingester.ingest(parsed: parsed, gmail: gmail)
end

class MailIngesterTest < ActiveSupport::TestCase
  test "keeps mail to info@ and files to the right client" do
    client = Client.create!(name: "Tashi", email: "tashi@example.com")
    result = ingest_raw(mail_raw(from: "tashi@example.com", message_id: "<a1@test>"),
      gmail: { gm_thrid: "thread-1", gm_msgid: "1001", labels: [ "\\Inbox" ] })
    assert_equal :stored, result[:status]
    assert_equal client, result[:conversation].linkable
    assert_equal "in", result[:message].direction
    assert_equal [ "\\Inbox" ], result[:message].label_list
  end

  test "keeps outbound mail from info@ and links by recipient" do
    client = Client.create!(name: "Maya", email: "maya@example.com")
    raw = mail_raw(from: "info@sherpaholidays.com", to: "maya@example.com", subject: "Re: trip", message_id: "<out1@test>")
    result = ingest_raw(raw, gmail: { gm_thrid: "thread-2", gm_msgid: "1002" })
    assert_equal :stored, result[:status]
    assert_equal "out", result[:message].direction
    assert_equal client, result[:conversation].linkable
  end

  test "drops personal mail with no info@ trace without storing it" do
    assert_no_difference([ "Conversation.count", "Message.count" ]) do
      result = ingest_raw(mail_raw(from: "friend@example.com", to: "captain@gmail.com", message_id: "<personal@test>"),
        gmail: { gm_thrid: "thread-x", gm_msgid: "9999" })
      assert_equal :filtered, result[:status]
    end
  end

  test "dedupes on gm_message_id and on Message-ID" do
    ingest_raw(mail_raw(from: "a@example.com", to: "info@sherpaholidays.com", message_id: "<dup@test>"),
      gmail: { gm_thrid: "t1", gm_msgid: "555" })
    assert_no_difference("Message.count") do
      again = ingest_raw(mail_raw(from: "a@example.com", to: "info@sherpaholidays.com", message_id: "<other@test>"),
        gmail: { gm_thrid: "t1", gm_msgid: "555" })
      assert_equal :duplicate, again[:status]
    end
    assert_no_difference("Message.count") do
      again = ingest_raw(mail_raw(from: "a@example.com", to: "info@sherpaholidays.com", message_id: "<dup@test>"),
        gmail: { gm_thrid: "t-other", gm_msgid: "556" })
      assert_equal :duplicate, again[:status]
    end
  end

  test "threads on X-GM-THRID and falls back to In-Reply-To" do
    first = ingest_raw(mail_raw(from: "b@example.com", message_id: "<first@test>"),
      gmail: { gm_thrid: "thread-9", gm_msgid: "901" })
    second = ingest_raw(mail_raw(from: "info@sherpaholidays.com", to: "b@example.com", message_id: "<second@test>"),
      gmail: { gm_thrid: "thread-9", gm_msgid: "902" })
    assert_equal first[:conversation].id, second[:conversation].id

    third = ingest_raw(mail_raw(from: "c@example.com", message_id: "<third@test>", in_reply_to: "<first@test>"),
      gmail: {})
    assert_equal first[:conversation].id, third[:conversation].id
  end

  test "unknown senders go to triage and never create records silently" do
    assert_no_difference([ "Client.count", "Lead.count", "Organization.count" ]) do
      result = ingest_raw(mail_raw(from: "newbie@example.com", message_id: "<new@test>"),
        gmail: { gm_thrid: "triage-1", gm_msgid: "7001" })
      assert_equal :stored, result[:status]
      assert_nil result[:conversation].linkable
      assert result[:conversation].triage?
    end
  end

  test "remembered EmailIdentity auto-links later mail" do
    client = Client.create!(name: "Linked", email: "linked@example.com")
    EmailIdentity.remember!("stranger@example.com", linkable: client)
    result = ingest_raw(mail_raw(from: "stranger@example.com", message_id: "<s1@test>"),
      gmail: { gm_thrid: "t-s", gm_msgid: "8001" })
    assert_equal client, result[:conversation].linkable
  end

  test "matches person email to the parent client" do
    client = Client.create!(name: "Family")
    client.people.create!(name: "Maya", email: "maya-person@example.com")
    result = ingest_raw(mail_raw(from: "maya-person@example.com", message_id: "<p1@test>"),
      gmail: { gm_thrid: "t-p", gm_msgid: "8002" })
    assert_equal client, result[:conversation].linkable
  end

  test "sanitizes html bodies on ingest" do
    raw = "From: h@example.com\r\nTo: info@sherpaholidays.com\r\nSubject: x\r\nMessage-ID: <h1@test>\r\nContent-Type: text/html; charset=UTF-8\r\n\r\n<p>hi</p><script>alert(1)</script>"
    result = ingest_raw(raw, gmail: { gm_thrid: "t-h", gm_msgid: "8003" })
    assert_not_includes result[:message].html_body.to_s, "<script"
  end

  test "stores attachments on the message" do
    client = Client.create!(name: "Attach", email: "attach@example.com")
    parsed = Mail::Ingester.parse_raw(mail_raw(from: "attach@example.com", message_id: "<att@test>"))
    parsed.attachments << { filename: "note.txt", content_type: "text/plain", data: "hello file" }
    result = Mail::Ingester.ingest(parsed: parsed, gmail: { gm_thrid: "t-att", gm_msgid: "8004" })
    assert result[:message].files.attached?
    assert_equal "note.txt", result[:message].files.first.filename.to_s
  end
end
