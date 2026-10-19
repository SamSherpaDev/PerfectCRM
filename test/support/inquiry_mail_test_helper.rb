module InquiryMailTestHelper
  # Synthetic fallback mail: intake failed before a reference was allocated.
  # Exercise real MIME parsing and ingestion, including HTML-only notifications.
  def ingest_inquiry(subject: "New inquiry from Synthetic Traveler: Nepal tour", html: false,
    from: "notifications@example.com", email: nil, headers: {}, body: nil, received_at: 1.hour.ago, provider_id: SecureRandom.uuid)
    email ||= "traveler-#{provider_id.to_s.tr('^a-zA-Z0-9', '').first(12).downcase}@example.com"
    body ||= if html
      "<h1>Website inquiry - CRM fallback</h1><p><strong>Name:</strong> Synthetic Traveler</p>" \
        "<p><strong>Email:</strong> #{email}</p><p><strong>Has in mind:</strong> Nepal tour</p>" \
        "<p><strong>Message:</strong><br>Can you help plan a trip for two?</p>"
    else
      "New website inquiry - reply to answer them directly.\n\nName: Synthetic Traveler\n" \
        "Email: #{email}\nHas in mind: Nepal tour\n\nMessage:\nCan you help plan a trip for two?"
    end
    raw = "From: #{from}\r\nTo: info@sherpaholidays.com\r\nSubject: #{subject}\r\n" \
      "Message-ID: <#{provider_id}@example.com>\r\nDate: #{received_at.rfc2822}\r\n" +
      headers.map { |name, value| "#{name}: #{value}\r\n" }.join +
      "Content-Type: text/#{html ? 'html' : 'plain'}; charset=UTF-8\r\n\r\n#{body}"
    parsed = Mail::Ingester.parse_raw(raw)
    parsed.received_at = received_at
    Mail::Ingester.ingest(parsed: parsed, provider: { message_id: provider_id })[:message]
  end
end
