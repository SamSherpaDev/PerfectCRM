require "test_helper"
require_relative "../support/quote_terms_test_helper"
require_relative "../support/google_sign_in_test_helper"
require_relative "../support/inquiry_mail_test_helper"

class TodayRequestsTest < ActionDispatch::IntegrationTest
  include QuoteTermsTestHelper
  include GoogleSignInTestHelper
  include InquiryMailTestHelper

  setup do
    sign_in
    @client = Client.create!(name: "Maya", email: "maya@example.com", perfectbook_contact_id: 11)
  end

  test "today renders the six tiles with sentence-case labels" do
    get root_path
    assert_response :success
    assert_select "h1", "Today"
    assert_select ".stat", count: 6
    assert_select ".stat", text: /Waiting on you/
    assert_select ".stat", text: /Follow-ups due/
    assert_select ".stat", text: /Quotes out/
    assert_select ".stat", text: /Overdue/
    assert_select ".stat", text: /New leads/
    assert_select ".stat", text: /Active clients/
  end

  test "Today lists unlinked inquiry notifications without creating leads, then labels resolved leads Added to New from email" do
    messages = [ ingest_inquiry(html: true), ingest_inquiry ]
    assert messages.all? { |message| message.conversation.triage? }
    assert_equal 0, Lead.count

    get root_path
    assert_response :success
    assert_equal 0, Lead.count
    assert_select "[aria-label='Added to New from email']", count: 0
    assert_select "[aria-label='Unlinked inquiries']" do
      assert_select "strong", "Unlinked inquiries: 2"
      messages.each { |message| assert_select "a[href=?]", inbox_thread_path(message.conversation) }
    end

    InquirySafetyNetJob.perform_now
    get root_path
    assert_response :success
    assert_equal 2, Lead.by_status("new").count
    assert_equal "2", stat_value("New leads")
    assert_select "[aria-label='Unlinked inquiries']", count: 0
    assert_select "[aria-label='Added to New from email']" do
      assert_select "strong", "Added to New from email: 2"
      messages.each do |message|
        lead = message.reload.conversation.linkable
        assert_instance_of Lead, lead
        assert_select "a[href=?]", lead_path(lead)
      end
    end
    messages.first.reload.conversation.linkable.mark_potential!
    messages.last.conversation.update!(ignored: true)
    get root_path
    assert_response :success
    assert_select "[aria-label='Added to New from email']", count: 0
    assert_select "[aria-label='Unlinked inquiries']", count: 0
  end

  test "today counts new leads and active clients" do
    Lead.create!(name: "Priya", email: "priya@example.com")
    Lead.create!(name: "Ken", email: "ken@example.com", status: "chatting")
    Lead.create!(name: "Ana", email: "ana@example.com", status: "lost", lost_reason: "price")
    Client.create!(name: "Retired Ray", email: "ray@example.com").archive!

    get root_path
    assert_response :success
    assert_equal "1", stat_value("New leads")
    assert_equal "1", stat_value("Active clients")
  end

  test "not yet called links every older inquiry oldest first and clears after a logged call" do
    travel_to Time.zone.local(2026, 10, 14, 12) do
      newer = Lead.create!(name: "Newer inquiry", received_at: 3.days.ago)
      older = Lead.create!(name: "Older inquiry", received_at: 5.days.ago)
      get root_path
      assert_response :success
      assert_select "section[aria-labelledby='not-yet-called-heading']" do
        assert_select "a", count: 2 do |links|
          assert_equal [ "Older inquiry", "Newer inquiry" ], links.map(&:text)
        end
        assert_select "a[href=?]", lead_path(older)
        assert_select "a[href=?]", lead_path(newer)
      end

      post lead_calls_path(older), params: { save_key: "first-contact-call", occurred_at: 1.hour.ago.iso8601,
        outcome: "voicemail", direction: "outbound" }
      assert_redirected_to lead_path(older, anchor: "record-details")
      get root_path
      assert_select "section[aria-labelledby='not-yet-called-heading']" do
        assert_select "a", count: 1
        assert_select "a[href=?]", lead_path(newer)
      end
    end
  end

  test "automatic-only inquiry shows the unanswered inbound preview until a call is logged" do
    lead = Lead.create!(name: "Demo inquiry", email: "demo@example.com")
    thread = Conversation.create!(linkable: lead, subject: "Trip")
    thread.messages.create!(direction: "in", status: "received", subject: "Trip",
      text_body: "Can we plan a trip?", sent_at: 2.days.ago)
    automatic = thread.messages.create!(direction: "out", status: "sent", subject: "Trip",
      to_addrs: lead.email, text_body: "Automatic welcome", sent_at: 2.days.ago + 1.minute)
    AutomaticFirstReply.create!(lead: lead, message: automatic, email: lead.email)
    get root_path
    assert_response :success
    assert_equal "1", stat_value("Waiting on you")
    assert_select "section[aria-labelledby='replies-heading']" do
      assert_select "li", text: /Can we plan a trip\?/
      assert_select "li", text: /Automatic welcome/, count: 0
    end

    post lead_calls_path(lead), params: { save_key: "demo-call-1", occurred_at: 1.day.ago.iso8601,
      outcome: "no_answer", direction: "outbound" }
    assert_redirected_to lead_path(lead, anchor: "record-details")
    get root_path
    assert_equal "0", stat_value("Waiting on you")
    assert_select "a[href=?]", inbox_thread_path(thread), count: 0
  end

  test "converted inquiries stay resolved by calls and wait again for new inbound" do
    lead = Lead.create!(name: "Converted inquiry", email: "converted@example.com")
    thread = Conversation.create!(linkable: lead, subject: "Converted trip")
    inbound = thread.messages.create!(direction: "in", status: "received",
      text_body: "Plan a trip", sent_at: 3.days.ago)
    automatic = thread.messages.create!(direction: "out", status: "sent", subject: "Trip",
      to_addrs: lead.email, text_body: "Welcome", sent_at: 3.days.ago + 1.minute)
    AutomaticFirstReply.create!(lead: lead, message: automatic, email: lead.email)
    post lead_calls_path(lead), params: { save_key: "conversion-call-1", occurred_at: 2.days.ago.iso8601,
      outcome: "connected", direction: "outbound" }
    post convert_lead_path(lead), params: { expected_client_id: "new" }
    client = lead.reload.converted_client
    assert_redirected_to client_path(client)
    assert_equal client, thread.reload.linkable
    assert_not thread.waiting_on_you?
    get root_path
    assert_equal "0", stat_value("Waiting on you")

    inbound.update!(sent_at: 1.day.ago)
    assert thread.waiting_on_you?
    get root_path
    assert_equal "1", stat_value("Waiting on you")

    other = Lead.create!(name: "Another inquiry", email: "another@example.com", existing_client: client)
    other_thread = Conversation.create!(linkable: other, subject: "Another trip")
    other_thread.messages.create!(direction: "in", status: "received",
      text_body: "A different trip", sent_at: 1.day.ago)
    other_automatic = other_thread.messages.create!(direction: "out", status: "sent", subject: "Another trip",
      to_addrs: other.email, text_body: "Welcome again", sent_at: 1.day.ago + 1.minute)
    AutomaticFirstReply.create!(lead: other, message: other_automatic, email: other.email)
    post convert_lead_path(other), params: { expected_client_id: client.id }
    assert_redirected_to client_path(client)
    assert_equal client, other_thread.reload.linkable
    assert other_thread.waiting_on_you?
    get root_path
    assert_equal "2", stat_value("Waiting on you")

    post client_calls_path(client), params: { inquiry_id: other.id, save_key: "other-inquiry-call",
      occurred_at: 1.hour.ago.iso8601, outcome: "connected", direction: "outbound" }
    assert_redirected_to client_path(client, anchor: "record-details")
    assert thread.waiting_on_you?
    assert_not other_thread.waiting_on_you?
    get root_path
    assert_equal "1", stat_value("Waiting on you")
    assert_select "a[href=?]", inbox_thread_path(thread)
    assert_select "a[href=?]", inbox_thread_path(other_thread), count: 0
    post client_calls_path(client), params: { inquiry_id: lead.id, save_key: "conversion-call-2",
      occurred_at: 1.hour.ago.iso8601, outcome: "voicemail", direction: "inbound" }
    assert_redirected_to client_path(client, anchor: "record-details")
    assert_not thread.waiting_on_you?
    get root_path
    assert_equal "0", stat_value("Waiting on you")
    assert_select "a[href=?]", inbox_thread_path(thread), count: 0
  end

  test "today lists follow-ups with one-tap complete and nudge" do
    template = Template.create!(name: "Deposit nudge", body: "Hi", purpose: "deposit_nudge")
    task = @client.tasks.create!(title: "Nudge Maya", due_on: Date.current, template: template)
    other = @client.tasks.create!(title: "Snoozed away", due_on: Date.current - 2)
    other.snooze!("week")

    get root_path
    assert_response :success
    assert_select "h2", text: "Follow-ups"
    assert_select "li", text: /Nudge Maya/
    assert_select "form[action=?]", complete_task_path(task)
    assert_select "a[href=?]", client_path(@client, template: template.id, task: task.id), text: "Nudge"
    assert_select "li", text: /Snoozed away/, count: 0
  end

  test "today shows departing soon and back from the mountains" do
    PerfectBook::Booking.create!(perfectbook_id: 200, perfectbook_contact_id: 11,
      trip_name: "Everest", start_date: Date.current + 5, party_size: 2, synced_at: Time.current)
    home = PerfectBook::Booking.create!(perfectbook_id: 201, perfectbook_contact_id: 11,
      trip_name: "Annapurna", end_date: Date.current - 2, synced_at: Time.current)

    get root_path
    assert_response :success
    assert_select "h2", text: "Departing soon"
    assert_select "li", text: /Everest/
    assert_select "h2", text: "Back from the mountains"
    assert_select "li", text: /Annapurna/
    assert_select "form[action=?]", create_review_ask_tasks_path
    assert_select "form input[name=booking_id][value='#{home.id}']"
  end

  test "today counts waiting replies and live quotes" do
    convo = @client.conversations.create!(subject: "Re: Everest dates")
    convo.messages.create!(direction: "in", from_address: "maya@example.com",
      subject: "Re: Everest dates", text_body: "Can we add a night?",
      status: "received", sent_at: 1.hour.ago)
    quote = Quote.new(client: @client, trip_name: "Everest Base Camp trek",
      party_size: 2, valid_until: Date.current + 7)
    quote.lines.build(description: "Everest Base Camp trek, 14 days",
      quantity: 1, unit_minor: 100_000, total_minor: 100_000)
    quote.save!
    complete_quote_terms(quote)
    quote.deliver!

    get root_path
    assert_response :success
    assert_select "a[href=?]", inbox_thread_path(convo), text: "Maya"
    assert_select ".stat-value", text: "1", count: 3
    assert_select "p", text: /No replies waiting/, count: 0
  end

  test "today with nothing to do shows the empty states" do
    get root_path
    assert_response :success
    assert_select "p", text: /Nothing owed this week/
    assert_select "p", text: /No replies waiting/
    assert_select "p", text: "No inquiries waiting for first contact."
    assert_select "[aria-label='Unlinked inquiries']", count: 0
  end

  private

  def stat_value(label)
    tile = css_select(".stat").find { |stat| stat.css("p").any? { |line| line.text == label } }
    assert tile, "no counts tile labeled #{label}"
    tile.at_css(".stat-value").text
  end
end
