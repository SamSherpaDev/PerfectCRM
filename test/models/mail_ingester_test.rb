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

def ingest_raw(raw, provider: {})
  parsed = Mail::Ingester.parse_raw(raw)
  Mail::Ingester.ingest(parsed: parsed, provider: provider)
end

class MailIngesterTest < ActiveSupport::TestCase
  test "keeps mail to info@ and files to the right client" do
    client = Client.create!(name: "Tashi", email: "tashi@example.com")
    result = ingest_raw(mail_raw(from: "tashi@example.com", message_id: "<a1@test>"),
      provider: { thread_id: "thread-1", message_id: "1001", labels: [ "\\Inbox" ] })
    assert_equal :stored, result[:status]
    assert_equal client, result[:conversation].linkable
    assert_equal "in", result[:message].direction
    assert_equal [ "\\Inbox" ], result[:message].label_list
  end

  test "keeps outbound mail from info@ and links by recipient" do
    client = Client.create!(name: "Maya", email: "maya@example.com")
    raw = mail_raw(from: "info@sherpaholidays.com", to: "maya@example.com", subject: "Re: trip", message_id: "<out1@test>")
    result = ingest_raw(raw, provider: { thread_id: "thread-2", message_id: "1002" })
    assert_equal :stored, result[:status]
    assert_equal "out", result[:message].direction
    assert_equal client, result[:conversation].linkable
  end

  test "drops personal mail with no info@ trace without storing it" do
    assert_no_difference([ "Conversation.count", "Message.count" ]) do
      result = ingest_raw(mail_raw(from: "friend@example.com", to: "captain@gmail.com", message_id: "<personal@test>"),
        provider: { thread_id: "thread-x", message_id: "9999" })
      assert_equal :filtered, result[:status]
    end
  end

  test "dedupes on provider_message_id and on Message-ID" do
    ingest_raw(mail_raw(from: "a@example.com", to: "info@sherpaholidays.com", message_id: "<dup@test>"),
      provider: { thread_id: "t1", message_id: "555" })
    assert_no_difference("Message.count") do
      again = ingest_raw(mail_raw(from: "a@example.com", to: "info@sherpaholidays.com", message_id: "<other@test>"),
        provider: { thread_id: "t1", message_id: "555" })
      assert_equal :duplicate, again[:status]
    end
    assert_no_difference("Message.count") do
      again = ingest_raw(mail_raw(from: "a@example.com", to: "info@sherpaholidays.com", message_id: "<dup@test>"),
        provider: { thread_id: "t-other", message_id: "556" })
      assert_equal :duplicate, again[:status]
    end
  end

  test "threads on the provider thread id and falls back to In-Reply-To" do
    first = ingest_raw(mail_raw(from: "b@example.com", message_id: "<first@test>"),
      provider: { thread_id: "thread-9", message_id: "901" })
    second = ingest_raw(mail_raw(from: "info@sherpaholidays.com", to: "b@example.com", message_id: "<second@test>"),
      provider: { thread_id: "thread-9", message_id: "902" })
    assert_equal first[:conversation].id, second[:conversation].id

    third = ingest_raw(mail_raw(from: "c@example.com", message_id: "<third@test>", in_reply_to: "<first@test>"),
      provider: {})
    assert_equal first[:conversation].id, third[:conversation].id
  end

  test "unknown senders go to triage and never create records silently" do
    assert_no_difference([ "Client.count", "Lead.count", "Organization.count" ]) do
      result = ingest_raw(mail_raw(from: "newbie@example.com", message_id: "<new@test>"),
        provider: { thread_id: "triage-1", message_id: "7001" })
      assert_equal :stored, result[:status]
      assert_nil result[:conversation].linkable
      assert result[:conversation].triage?
    end
  end

  test "remembered EmailIdentity auto-links later mail" do
    client = Client.create!(name: "Linked", email: "linked@example.com")
    EmailIdentity.remember!("stranger@example.com", linkable: client)
    result = ingest_raw(mail_raw(from: "stranger@example.com", message_id: "<s1@test>"),
      provider: { thread_id: "t-s", message_id: "8001" })
    assert_equal client, result[:conversation].linkable
  end

  test "matches person email to the parent client" do
    client = Client.create!(name: "Family")
    client.people.create!(name: "Maya", email: "maya-person@example.com")
    result = ingest_raw(mail_raw(from: "maya-person@example.com", message_id: "<p1@test>"),
      provider: { thread_id: "t-p", message_id: "8002" })
    assert_equal client, result[:conversation].linkable
  end

  test "sanitizes html bodies on ingest" do
    raw = "From: h@example.com\r\nTo: info@sherpaholidays.com\r\nSubject: x\r\nMessage-ID: <h1@test>\r\nContent-Type: text/html; charset=UTF-8\r\n\r\n<p>hi</p><script>alert(1)</script>"
    result = ingest_raw(raw, provider: { thread_id: "t-h", message_id: "8003" })
    assert_not_includes result[:message].html_body.to_s, "<script"
  end

  test "stores attachments on the message" do
    client = Client.create!(name: "Attach", email: "attach@example.com")
    parsed = Mail::Ingester.parse_raw(mail_raw(from: "attach@example.com", message_id: "<att@test>"))
    parsed.attachments << { filename: "note.txt", content_type: "text/plain", data: "hello file" }
    result = Mail::Ingester.ingest(parsed: parsed, provider: { thread_id: "t-att", message_id: "8004" })
    assert result[:message].files.attached?
    assert_equal "note.txt", result[:message].files.first.filename.to_s
  end
  test "delivery headers retain alias mail in ingestion" do
    %w[Bcc Delivered-To X-Original-To].each_with_index do |header, index|
      raw = "#{header}: info@sherpaholidays.com\r\n" + mail_raw(from: "sender@example.com", to: "captain@gmail.com", message_id: "<delivery#{index}@test>")
      parsed = Mail::Ingester.parse_raw(raw)
      assert_equal :stored, Mail::Ingester.ingest(parsed: parsed, provider: {})[:status]
    end
  end

  test "failed upload rolls back ingestion and retries completely" do
    client = Client.create!(name: "Retry", email: "retry@example.com")
    parsed = Mail::Ingester.parse_raw(mail_raw(from: client.email, message_id: "<retry@test>"))
    parsed.attachments << { filename: "route.txt", content_type: "text/plain", data: "route" }
    service = ActiveStorage::Blob.service
    assert_no_difference([ "Message.count", "Conversation.count", "ActiveStorage::Blob.count" ]) do
      service.stub(:upload, ->(*) { raise IOError, "upload failed" }) do
        assert_raises(IOError) { Mail::Ingester.ingest(parsed: parsed, provider: { message_id: "retry" }) }
      end
    end
    result = Mail::Ingester.ingest(parsed: parsed, provider: { message_id: "retry" })
    assert_equal :stored, result[:status]
    assert_equal client, result[:conversation].linkable
    assert_equal "route", result[:message].files.first.download
  end

  test "failed holding upload rolls back all arrivals and allows the same message to retry" do
    parsed = Mail::Ingester.parse_raw(mail_raw(from: "held-retry@example.com", message_id: "<held-retry@test>"))
    parsed.attachments = [
      { filename: "route.txt", content_type: "text/plain", data: "route bytes" },
      { filename: "passport.pdf", content_type: "application/pdf", data: "passport bytes" },
      { filename: "visa.png", content_type: "image/png", data: "visa bytes" }
    ]
    service = ActiveStorage::Blob.service
    upload = service.method(:upload)
    keys = []
    failing_upload = lambda do |key, io, **options|
      keys << key
      upload.call(key, io, **options)
      raise IOError, "holding upload failed" if keys.size == 3
    end
    assert_no_difference([ "Message.count", "Conversation.count", "DocumentHolding.count",
      "ActiveStorage::Blob.count", "ActiveStorage::Attachment.count", "Note.count" ]) do
      service.stub(:upload, failing_upload) do
        assert_raises(IOError) do
          Mail::Ingester.ingest(parsed: parsed, provider: { message_id: "held-retry" })
        end
      end
    end
    assert_equal 3, keys.size
    keys.each { |key| assert_not service.exist?(key) }

    result = Mail::Ingester.ingest(parsed: parsed, provider: { message_id: "held-retry" })
    assert_equal :stored, result[:status]
    message = result[:message].reload
    assert_equal "route bytes", message.files.first.download
    assert_equal [ "passport bytes", "visa bytes" ],
      DocumentHolding.where(message: message).order(:id).map { |holding| holding.file.download }
    assert_equal 2, message.held_attachments.size
    assert_equal :duplicate, Mail::Ingester.ingest(parsed: parsed, provider: { message_id: "held-retry" })[:status]
  end

  test "ignored identities skip triage on new threads" do
    EmailIdentity.remember!("ignored@example.com", ignored: true)
    result = ingest_raw(mail_raw(from: "ignored@example.com", message_id: "<ignored@test>"))
    assert result[:conversation].ignored?
    assert_not Conversation.triage.exists?(result[:conversation].id)
  end

  test "lead conversion transfers mail and resolves original person owners" do
    lead = Lead.create!(name: "Traveler", email: "lead-mail@example.com", source: "email")
    lead.people.create!(name: "Companion", email: "companion@example.com")
    EmailIdentity.remember!("alias@example.com", linkable: lead)
    first = ingest_raw(mail_raw(from: lead.email, message_id: "<lead-mail@test>"))
    client = lead.convert_to_client!
    assert_equal client, first[:conversation].reload.linkable
    assert_equal client, EmailIdentity.find_for("alias@example.com").linkable
    %w[lead-mail@example.com companion@example.com alias@example.com].each_with_index do |email, index|
      result = ingest_raw(mail_raw(from: email, message_id: "<converted#{index}@test>"))
      assert_equal client, result[:conversation].linkable
    end
  end

  test "keeps all ordinary attachments and flags documents while explaining oversize skips" do
    parsed = Mail::Ingester.parse_raw(mail_raw(from: "files@example.com", message_id: "<many-files@test>"))
    parsed.attachments = 11.times.map { |i| { filename: "route#{i}.txt", content_type: "text/plain", data: "route" } }
    parsed.attachments << { filename: "passport.pdf", content_type: "application/pdf", data: "passport" }
    parsed.attachments << { filename: "large.txt", content_type: "text/plain", data: "a" * (25.megabytes + 1) }
    result = Mail::Ingester.ingest(parsed: parsed, provider: {})
    assert_equal 11, result[:message].files.count
    assert_equal "passport.pdf", result[:message].held_attachments.first["filename"]
    assert_includes result[:message].attachment_notices.first, "25 MB"
    assert Conversation.needs_triage.exists?(result[:conversation].id)
  end

  test "single part legacy charset text and HTML are converted to UTF-8" do
    %w[plain html].each do |type|
      raw = "From: accent@example.com\r\nTo: info@sherpaholidays.com\r\nMessage-ID: <accent-#{type}@test>\r\nContent-Type: text/#{type}; charset=ISO-8859-1\r\nContent-Transfer-Encoding: quoted-printable\r\n\r\nAndr=E9"
      result = ingest_raw(raw)
      body = type == "html" ? result[:message].reload.html_body : result[:message].reload.text_body
      assert_equal "André", body
      assert body.valid_encoding?
    end
  end

  test "matching always excludes the configured mailbox" do
    client = Client.create!(name: "Business mailbox", email: Mail.mailbox_address)
    EmailIdentity.remember!(Mail.mailbox_address, linkable: client)
    assert_nil Mail::Matcher.call([ Mail.mailbox_address ]).linkable
  end

  test "sensitive documents wait in the short-lived holding area, never as message files" do
    files = [
      { filename: "passport.pdf", content_type: "application/pdf", data: "passport bytes" },
      { filename: "visa.png", content_type: "image/png", data: "visa bytes" },
      { filename: "insurance.txt", content_type: "text/plain", data: "insurance bytes" },
      { filename: "traveler-ID.txt", content_type: "text/plain", data: "ID bytes" },
      { filename: "date_of_birth.txt", content_type: "text/plain", data: "birth bytes" },
      { filename: "document.txt", content_type: "application/x-passport", data: "typed bytes" },
      { filename: "document.pdf", content_type: "application/pdf", data: pdf_with_title("Passport copy") },
      { filename: "unreadable.pdf", content_type: "application/pdf", data: "unreadable" }
    ]
    parsed = Mail::Ingester.parse_raw(mail_raw(from: "held@example.com", message_id: "<held@test>"))
    parsed.attachments = files
    result = Mail::Ingester.ingest(parsed: parsed, provider: {})
    message = result[:message].reload
    assert_empty message.files
    assert_equal files.map { |file| { "filename" => file[:filename], "byte_size" => file[:data].bytesize,
      "content_type" => file[:content_type], "status" => "held: send to PerfectBook",
      "holding_id" => DocumentHolding.find_by!(message: message, filename: file[:filename]).id } },
      message.held_attachments
    holdings = DocumentHolding.where(message: message).to_a
    assert_equal files.size, holdings.size
    holdings.each do |holding|
      assert_in_delta 24.hours.from_now.to_i, holding.expires_at.to_i, 60
      assert holding.live?
    end
    assert_match(/holding area/, Note.find_by!(notable: result[:conversation]).body)
  end

  test "holding-area bytes purge on expiry and never outlive the 24-hour window" do
    parsed = Mail::Ingester.parse_raw(mail_raw(from: "held@example.com", message_id: "<expiry@test>"))
    parsed.attachments = [ { filename: "passport.pdf", content_type: "application/pdf", data: "passport bytes" } ]
    result = Mail::Ingester.ingest(parsed: parsed, provider: {})
    message = result[:message].reload
    holding = DocumentHolding.find_by!(message: message)
    key = holding.file.blob.key
    assert holding.file.blob.service.exist?(key)
    travel 25.hours do
      DocumentHoldingsPurgeJob.perform_now
    end
    assert_empty DocumentHolding.where(message: message)
    assert_not ActiveStorage::Blob.service.exist?(key)
    entry = message.reload.held_attachments.first
    assert_nil entry["holding_id"]
    assert_match(/expired/, entry["status"])
  end

  test "ordinary PDF with a nonsensitive title remains downloadable" do
    data = pdf_with_title("Trip itinerary")
    parsed = Mail::Ingester.parse_raw(mail_raw(from: "route@example.com", message_id: "<ordinary-pdf@test>"))
    parsed.attachments << { filename: "itinerary.pdf", content_type: "application/pdf", data: data }
    result = Mail::Ingester.ingest(parsed: parsed, provider: {})
    assert_empty result[:message].held_attachments
    assert_equal data, result[:message].files.first.download
  end

  test "attachment disposition is screened independently of MIME nesting" do
    part = "Content-Type: text/plain\r\nContent-Disposition: attachment; filename=insurance.txt\r\n\r\nPRIVATE DOCUMENT"
    [ part, "Content-Type: multipart/mixed; boundary=parts\r\n\r\n--parts\r\n#{part}\r\n--parts--" ].each_with_index do |body, index|
      raw = "From: documents@example.com\r\nTo: info@sherpaholidays.com\r\nMessage-ID: <disposition#{index}@test>\r\n#{body}"
      result = ingest_raw(raw)
      assert_nil result[:message].text_body
      assert_nil result[:message].html_body
      assert_empty result[:message].files
      entry = result[:message].held_attachments.first
      assert_equal "insurance.txt", entry["filename"]
      assert_equal "held: send to PerfectBook", entry["status"]
      assert DocumentHolding.find_by!(id: entry["holding_id"]).live?
    end
  end

  test "ordinary single part attachment stays a downloadable file" do
    raw = "From: documents@example.com\r\nTo: info@sherpaholidays.com\r\nContent-Type: text/plain\r\nContent-Disposition: attachment; filename=itinerary.txt\r\n\r\nOrdinary itinerary"
    result = ingest_raw(raw)
    assert_nil result[:message].text_body
    assert_equal "Ordinary itinerary", result[:message].files.first.download
  end

  test "forwarded emails hold enclosed sensitive attachments outside the message files" do
    enclosed = "From: traveler@example.com\r\nContent-Type: multipart/mixed; boundary=inside\r\n\r\n--inside\r\nContent-Type: text/plain\r\n\r\nForwarded note\r\n--inside\r\nContent-Type: application/pdf\r\nContent-Disposition: attachment; filename=passport.pdf\r\n\r\nPRIVATE PASSPORT BYTES\r\n--inside--\r\n"
    2.times do |index|
      enclosed = "Content-Type: message/rfc822\r\nContent-Disposition: attachment; filename=trip.eml\r\nContent-Transfer-Encoding: base64\r\n\r\n#{Base64.strict_encode64(enclosed)}"
      raw = "From: forwarder@example.com\r\nTo: info@sherpaholidays.com\r\nMessage-ID: <forwarded#{index}@test>\r\n#{enclosed}"
      result = ingest_raw(raw)
      assert_empty result[:message].files
      assert_equal [ "passport.pdf" ], result[:message].held_attachments.map { |file| file["filename"] }
      assert_equal "held: send to PerfectBook", result[:message].held_attachments.first["status"]
      assert_nil result[:message].text_body
      assert_nil result[:message].html_body
    end
  end

  test "forwarded mail without sensitive enclosures remains downloadable" do
    enclosed = "From: traveler@example.com\r\nSubject: Trip dates\r\n\r\nOrdinary forwarded note"
    raw = "From: forwarder@example.com\r\nTo: info@sherpaholidays.com\r\nContent-Type: message/rfc822\r\nContent-Disposition: attachment; filename=trip.eml\r\n\r\n#{enclosed}"
    result = ingest_raw(raw)
    assert_empty result[:message].held_attachments
    downloaded = ::Mail.read_from_string(result[:message].files.first.download)
    assert_equal [ "traveler@example.com" ], downloaded.from
    assert_equal "Trip dates", downloaded.subject
    assert_equal "Ordinary forwarded note", downloaded.body.decoded
  end

  test "safe enclosures survive a forwarded email with a sensitive enclosure" do
    enclosed = "Content-Type: multipart/mixed; boundary=inside\r\n\r\n--inside\r\nContent-Type: text/plain\r\nContent-Disposition: attachment; filename=insurance.txt\r\n\r\nPRIVATE\r\n--inside\r\nContent-Type: text/plain\r\nContent-Disposition: attachment; filename=itinerary.txt\r\n\r\nOrdinary itinerary\r\n--inside--\r\n"
    raw = "From: forwarder@example.com\r\nTo: info@sherpaholidays.com\r\nContent-Type: message/rfc822\r\nContent-Disposition: attachment; filename=trip.eml\r\n\r\n#{enclosed}"
    result = ingest_raw(raw)
    assert_equal [ "insurance.txt" ], result[:message].held_attachments.map { |file| file["filename"] }
    assert_equal [ "itinerary.txt" ], result[:message].files.map { |file| file.filename.to_s }
    assert_equal "Ordinary itinerary", result[:message].files.first.download
  end

  private

  def pdf_with_title(title)
    encoded_title = "FEFF" + title.encode("UTF-16BE").unpack1("H*")
    objects = [ "<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Kids [] /Count 0 >>", "<< /Title <#{encoded_title}> >>" ]
    pdf = +"%PDF-1.4\n"
    offsets = objects.each_with_index.map do |object, index|
      offset = pdf.bytesize
      pdf << "#{index + 1} 0 obj\n#{object}\nendobj\n"
      offset
    end
    xref = pdf.bytesize
    pdf << "xref\n0 4\n0000000000 65535 f \n"
    offsets.each { |offset| pdf << format("%010d 00000 n \n", offset) }
    pdf << "trailer\n<< /Size 4 /Root 1 0 R /Info 3 0 R >>\nstartxref\n#{xref}\n%%EOF\n"
  end
end
