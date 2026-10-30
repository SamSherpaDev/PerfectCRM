require "test_helper"
require_relative "../support/google_sign_in_test_helper"

class InboxRequestsTest < ActionDispatch::IntegrationTest
  include GoogleSignInTestHelper

  setup do
    sign_in
  end

  test "index renders tabs with icons and counts" do
    client = Client.create!(name: "Tashi", email: "tashi@example.com")
    conversation = Conversation.create!(subject: "Everest", linkable: client, last_message_at: Time.current)
    conversation.messages.create!(direction: "in", from_address: "tashi@example.com",
      to_addresses: [ "info@sherpaholidays.com" ], subject: "Everest", sent_at: Time.current, text_body: "Hi")

    get inbox_path
    assert_response :success
    assert_select "nav.tabs a", text: /Waiting on you/
    assert_select "nav.tabs a", text: /Waiting on them/
    assert_select "nav.tabs a", text: /All/
    assert_select "nav.tabs a", text: /Triage/
    assert_select "a", text: /Everest/
  end

  test "spam archive removes threads from inbox queues and restoration returns them" do
    lead = Lead.create!(name: "Spam inquiry")
    thread = Conversation.create!(linkable: lead, subject: "Spam thread")
    thread.messages.create!(direction: "in", sent_at: 1.hour.ago, text_body: "Hello")
    replied = Conversation.create!(linkable: lead, subject: "Replied spam thread")
    replied.messages.create!(direction: "out", status: "sent", sent_at: Time.current,
      to_addrs: "traveler@example.test", subject: "Replied spam thread", text_body: "Reply")

    get inbox_path(tab: "waiting")
    assert_select "a[href=?]", inbox_thread_path(thread), count: 1
    assert_includes Conversation.waiting_on_them, replied

    patch mark_as_spam_lead_path(lead)
    assert_redirected_to leads_path(tab: "new")
    [ "waiting", "waiting_them", "all" ].each do |tab|
      get inbox_path(tab: tab)
      assert_response :success
      assert_select "a[href=?]", inbox_thread_path(thread), count: 0
      assert_select "a[href=?]", inbox_thread_path(replied), count: 0
      [ [ "waiting", "Waiting on you" ], [ "waiting_them", "Waiting on them" ], [ "all", "All" ] ].each do |key, label|
        assert_select "nav.tabs a[href=?]", inbox_path(tab: key), text: /#{label}.*0/m
      end
    end
    [ thread, replied ].each do |conversation|
      assert_not_includes Conversation.waiting_on_you, conversation
      assert_not_includes Conversation.waiting_on_them, conversation
    end

    patch not_spam_lead_path(lead)
    assert_redirected_to leads_path(tab: "new")
    get inbox_path(tab: "waiting")
    assert_select "a[href=?]", inbox_thread_path(thread), count: 1
    get inbox_path(tab: "waiting_them")
    assert_select "a[href=?]", inbox_thread_path(replied), count: 1
    assert_select "a[href=?]", inbox_thread_path(thread), count: 0
    assert_includes Conversation.waiting_on_you, thread
    assert_includes Conversation.waiting_on_them, replied
  end

  test "triage tab shows suggested clients" do
    conversation = Conversation.create!(subject: "New ask", last_message_at: Time.current)
    conversation.messages.create!(direction: "in", from_address: "newbie@example.com",
      to_addresses: [ "info@sherpaholidays.com" ], subject: "New ask", sent_at: Time.current, text_body: "Hi")
    get inbox_path(tab: "triage")
    assert_response :success
    assert_select "a", text: /New ask/
  end

  test "thread view clears the unread mark" do
    client = Client.create!(name: "Maya", email: "maya@example.com")
    conversation = Conversation.create!(subject: "Dates", linkable: client, last_message_at: Time.current)
    conversation.messages.create!(direction: "in", from_address: "maya@example.com",
      to_addresses: [ "info@sherpaholidays.com" ], subject: "Dates", sent_at: Time.current, text_body: "When?")
    assert_equal 1, conversation.reload.unread_count

    get inbox_thread_path(conversation)
    assert_response :success
    assert_equal 0, conversation.reload.unread_count
    assert_select "article.stone-in", minimum: 1
  end

  test "client page shows the email stream" do
    client = Client.create!(name: "Stream", email: "stream@example.com")
    conversation = Conversation.create!(subject: "Stream sub", linkable: client, last_message_at: Time.current)
    conversation.messages.create!(direction: "in", from_address: "stream@example.com",
      to_addresses: [ "info@sherpaholidays.com" ], subject: "Stream sub", sent_at: Time.current, text_body: "hello stream")
    get client_path(client)
    assert_response :success
    assert_select "h2", text: "Timeline"
    assert_select ".timeline .ev", minimum: 1
  end
  test "record timeline pages long histories with the full expanded body" do
    client = Client.create!(name: "Long history", email: "history@example.com")
    21.times do |index|
      conversation = Conversation.create!(linkable: client, subject: "History #{index}")
      conversation.messages.create!(direction: "in", from_address: client.email, sent_at: index.minutes.ago,
        text_body: index.zero? ? "x" * 4100 + " final itinerary detail" : "message #{index}")
    end
    get client_path(client)
    assert_response :success
    assert_select ".timeline .ev", count: 21
    assert_select ".timeline details", text: /final itinerary detail/
    assert_select "a", { text: "Load older", count: 0 }
    30.times do |index|
      conversation = Conversation.create!(linkable: client, subject: "Older #{index}")
      conversation.messages.create!(direction: "in", from_address: client.email, sent_at: (21 + index).minutes.ago,
        text_body: "older message #{index}")
    end
    get client_path(client)
    assert_response :success
    assert_select ".timeline .ev", count: 50
    assert_select "a", text: "Load older"
    older = css_select("a").find { |a| a.text == "Load older" }["href"]
    get older
    assert_response :success
    assert_select ".timeline .ev", count: 1
    assert_select ".timeline", text: /older message 29/
    newer = css_select("a").find { |a| a.text == "Newer" }["href"]
    get URI.join(request.url, newer).to_s
    assert_select ".timeline .ev", count: 50
    assert_select ".timeline details", text: /final itinerary detail/
  end

  test "inbox exposes the fifty first conversation" do
    51.times { |index| Conversation.create!(subject: "Page thread #{index}", last_message_at: index.minutes.ago) }
    get inbox_path(tab: "all")
    older = css_select("a").find { |a| a.text == "Load older" }["href"]
    get older
    assert_response :success
    assert_select "a", text: "Page thread 50"
  end

  test "sensitive attachment appears in triage even on a linked conversation" do
    client = Client.create!(name: "Review files", email: "review-files@example.com")
    parsed = Mail::Ingester.parse_raw("From: #{client.email}\r\nTo: info@sherpaholidays.com\r\nSubject: Passport review\r\n\r\nAttached")
    parsed.attachments << { filename: "passport.pdf", content_type: "application/pdf", data: "file" }
    result = Mail::Ingester.ingest(parsed: parsed, provider: {})
    get inbox_path(tab: "triage")
    assert_response :success
    assert_select "a", text: "Passport review"
    get inbox_thread_path(result[:conversation])
    assert_select "span", text: "held: send to PerfectBook"
    assert_select "p", text: /holding area/
    assert_select "a", text: "Download", count: 0
    assert_select "a", text: "Send to PerfectBook", count: 1
  end

  test "waiting count excludes unknown senders just like the list" do
    conversation = Conversation.create!(subject: "Unknown waiting")
    conversation.messages.create!(direction: "in", from_address: "unknown-count@example.com", sent_at: Time.current)
    get inbox_path(tab: "waiting")
    assert_response :success
    assert_select "nav.tabs a[href=?]", inbox_path(tab: "waiting"), text: /Waiting on you.*0/m
    assert_select "a", text: "Unknown waiting", count: 0
  end

  test "single part sensitive attachment never appears as message body" do
    raw = "From: sender@example.com\r\nTo: info@sherpaholidays.com\r\nSubject: Document\r\nContent-Type: text/plain\r\nContent-Disposition: attachment; filename=insurance.txt\r\n\r\nPRIVATE INSURANCE CONTENT"
    result = Mail::Ingester.ingest(parsed: Mail::Ingester.parse_raw(raw), provider: {})
    get inbox_thread_path(result[:conversation])
    assert_response :success
    assert_not_includes response.body, "PRIVATE INSURANCE CONTENT"
    assert_select "span", text: "held: send to PerfectBook"
    assert_nil result[:message].reload.text_body
    assert_nil result[:message].html_body
    assert_empty result[:message].files
  end

  test "inbox loads only latest messages while finding older document flags" do
    client = Client.create!(name: "History", email: "history-load@example.com")
    conversation = Conversation.create!(subject: "Long thread", linkable: client)
    30.times do |index|
      conversation.messages.create!(direction: "in", from_address: client.email, sent_at: index.minutes.ago,
        text_body: index.zero? ? "Latest preview" : "Old body #{index}",
        held_attachments: index == 29 ? [ { "filename" => "insurance.txt", "status" => "held: collect in PerfectBook" } ] : [])
    end
    instantiated = Hash.new(0)
    subscriber = ->(*args) do
      payload = args.last
      instantiated[payload[:class_name]] += payload[:record_count]
    end
    ActiveSupport::Notifications.subscribed(subscriber, "instantiation.active_record") do
      get inbox_path(tab: "all")
    end
    assert_response :success
    assert_select "p", text: "Latest preview"
    assert_select "span", text: "Review sensitive document"
    assert_equal 1, instantiated["Message"]
    assert_equal 0, instantiated["ActiveStorage::Attachment"]
    assert_equal 0, instantiated["ActiveStorage::Blob"]
  end

  test "HTML bodies render once and long HTML stays inside expansion" do
    conversation = Conversation.create!(subject: "HTML conversation")
    short = conversation.messages.create!(direction: "in", sent_at: Time.current, html_body: "<strong>Short HTML content</strong>")
    long = conversation.messages.create!(direction: "in", sent_at: Time.current, html_body: "<p>#{'Long content ' * 70}</p><strong>Unique ending</strong>")
    get inbox_thread_path(conversation)
    assert_response :success
    short_article = css_select("#message-#{short.id}").first
    assert_equal 1, short_article.text.scan("Short HTML content").length
    assert_select "#message-#{short.id} strong", text: "Short HTML content", count: 1
    assert_select "#message-#{long.id} details strong", text: "Unique ending", count: 1
    assert_equal 1, css_select("#message-#{long.id}").first.text.scan("Unique ending").length
  end

  test "thread rows leave out the CRM signature logo on inbound and outbound mail while listing real files" do
    logo = "\x89PNG\r\n\x1A\n".b + [ 13 ].pack("N") + "IHDR" + [ 120, 40 ].pack("NN") + "\x08\x02\x00\x00\x00inbox-logo".b
    Setting.current.signature_logo.attach(io: StringIO.new(logo), filename: "signature-logo.png", content_type: "image/png")
    client = Client.create!(name: "Daniel Loveless", email: "daniel@example.com")
    conversation = Conversation.create!(subject: "Everest Base Camp", linkable: client, last_message_at: Time.current)
    outbound = conversation.messages.create!(direction: "out", status: "sent", to_addrs: client.email,
      subject: "Everest Base Camp", text_body: "Here is your itinerary.", sent_at: 2.days.ago)
    outbound.files.attach(io: StringIO.new("%PDF-1.4 itinerary"), filename: "itinerary.pdf", content_type: "application/pdf")
    outbound.files.attach(io: StringIO.new(logo), filename: "signature-logo.png", content_type: "image/png")
    reply = conversation.messages.create!(direction: "in", from_address: client.email,
      subject: "Re: Everest Base Camp", text_body: "Looks great!", sent_at: 1.day.ago)
    reply.files.attach(io: StringIO.new(logo), filename: "signature-logo.png", content_type: "image/png")
    itinerary = outbound.reload.files.find { |file| file.filename.to_s == "itinerary.pdf" }
    logo_files = [ outbound.files.find { |file| file.filename.to_s == "signature-logo.png" }, reply.reload.files.first ]

    get inbox_thread_path(conversation)
    assert_response :success
    assert_select "ul.thread-attachments", count: 1
    assert_select "ul.thread-attachments li.attachment-row", count: 1
    assert_select "li.attachment-row", text: /itinerary\.pdf/, count: 1
    assert_select "li.attachment-row a[href=?]", new_document_handoff_path(attachment_id: itinerary.id), count: 1
    logo_files.each do |file|
      assert_select "a[href=?]", attachment_path(file.id), count: 0
      assert_select "a[href=?]", new_document_handoff_path(attachment_id: file.id), count: 0
    end
    assert_equal 2, outbound.files.count
    assert_equal 1, reply.files.count
  ensure
    Setting.current.signature_logo.purge if Setting.current.signature_logo.attached?
  end
end
