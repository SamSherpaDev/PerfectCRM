require "test_helper"
require_relative "../support/google_sign_in_test_helper"

class OutboundFollowupReviewTest < ActionDispatch::IntegrationTest
  include GoogleSignInTestHelper
  include ActiveJob::TestHelper

  setup do
    @client = Client.create!(name: "Maya", email: "maya@example.com", perfectbook_contact_id: 101)
    @client.people.create!(name: "Pemba", email: "pemba@example.com")
    @template = Template.create!(name: "Trip", purpose: "custom", subject: "Hi {{first_name}}",
      body: "{{full_name}}: {{trip}} {{balance_due}} {{invoice_number}} {{my_name}} {{signature}}")
    PerfectBook::Booking.create!(perfectbook_id: 501, perfectbook_contact_id: 101,
      departure_id: 701, trip_name: "Maya trek", balance_due_minor: 11100, invoice_number: "MAYA", synced_at: Time.current)
    PerfectBook::Departure.create!(perfectbook_id: 701, trip_name: "Trip", synced_at: Time.current)
    Setting.current.update!(sender_name: "Captain", email_signature: "Best wishes")
    sign_in
  end

  test "exact recipient booking and identity are used for preview and send" do
    PerfectBook::Contact.create!(perfectbook_id: 102, name: "Pemba", email: "pemba@example.com", synced_at: Time.current)
    PerfectBook::Booking.create!(perfectbook_id: 502, perfectbook_contact_id: 102,
      departure_id: 701, trip_name: "Pemba trek", balance_due_minor: 22200, invoice_number: "PEMBA", synced_at: Time.current)
    [ nil, 701 ].each do |departure|
      post merge_templates_path, params: { template_id: @template.id, departure_id: departure, recipients: "pemba@example.com" }
      assert_select "section[aria-label='Merged messages']", text: /Pemba: Pemba trek \$222.00 PEMBA/
      assert_select "section[aria-label='Merged messages']", text: /Maya/, count: 0
      post group_sends_path, params: { template_id: @template.id, departure_id: departure, recipients: "pemba@example.com" }
      assert_equal "Hi Pemba", Message.last.subject
      assert_includes Message.last.text_body, "Pemba trek $222.00 PEMBA"
    end
  end

  test "recipient identity retains advisor details from the CRM owner" do
    advisor = Organization.create!(name: "Adventure advisor")
    @client.update!(referred_by_organization: advisor)
    PerfectBook::Contact.create!(perfectbook_id: 101, name: "Maya", email: @client.email, synced_at: Time.current)
    @template.update!(body: "{{full_name}}: {{advisor_name}}")
    post group_sends_path, params: { template_id: @template.id, recipients: @client.email }
    assert_includes Message.last.text_body, "Maya: Adventure advisor"
    get reply_context_templates_path, params: { owner_type: "Client", owner_id: @client.id, to: @client.email }
    assert_equal "Adventure advisor", response.parsed_body["context"]["advisor_name"]
  end

  test "fallback booking is labeled and never overrides the recipient name" do
    post merge_templates_path, params: { template_id: @template.id, departure_id: 701, recipients: "pemba@example.com" }
    assert_select ".hint", text: "Booking reference: Maya's booking."
    assert_select "section[aria-label='Merged messages']", text: /Pemba: Maya trek \$111.00 MAYA/
    PerfectBook::Contact.create!(perfectbook_id: 102, name: "Pemba", email: "pemba@example.com", synced_at: Time.current)
    post merge_templates_path, params: { template_id: @template.id, departure_id: 701, recipients: "pemba@example.com" }
    assert_select "section[aria-label='Merged messages']", text: /Missing: trip/
    assert_select ".hint", text: /Booking reference:/, count: 0
  end

  test "unknown names stay missing while known sender settings render" do
    post group_sends_path, params: { template_id: @template.id, recipients: "stranger@example.com" }
    message = Message.last
    assert_equal "Hi [missing: first_name]", message.subject
    assert_includes message.text_body, "[missing: full_name]"
    assert_includes message.text_body, "Captain Best wishes"
    assert_not_includes message.text_body, "stranger@example.com"
    assert_nil message.owner
  end

  test "unowned failed group messages can be retried from their summary" do
    group = GroupSend.create!(template: @template, total_count: 1)
    message = Outbound::Composer.call(owner: nil, group_send: group,
      params: { to: "stranger@example.com", subject: "Hi", body: "Original words" })
    message.mark_failed!("SMTP unavailable")
    get group_send_path(group)
    assert_select "form[action=?]", retry_message_path(message)
    assert_no_difference("Message.count") do
      assert_enqueued_jobs 1, only: OutboundDeliveryJob do
        post retry_message_path(message)
      end
    end
    assert_redirected_to group_send_path(group)
    assert_equal "queued", message.reload.status
    assert_includes message.text_body, "Original words"
    assert_enqueued_jobs 0, only: OutboundDeliveryJob do
      post retry_message_path(message)
    end
  end

  test "inbox materializes only the latest message for each thread" do
    conversation = @client.conversations.create!(subject_line: "Thread")
    12.times do |i|
      conversation.messages.create!(direction: "outbound", status: "sent", subject: "Older #{i}",
        text_body: "Old body", to_addrs: @client.email, sent_at: 2.days.ago)
    end
    latest = conversation.messages.create!(direction: "outbound", status: "sent", subject: "Latest",
      text_body: "Latest body", to_addrs: @client.email, sent_at: 1.day.ago)
    conversation.messages.create!(direction: "outbound", status: "sent", subject: "Imported old message",
      text_body: "Old body", to_addrs: @client.email, sent_at: 3.days.ago)
    counts = []
    callback = ->(*args) { payload = args.last; counts << payload[:record_count] if payload[:class_name] == "Message" }
    ActiveSupport::Notifications.subscribed(callback, "instantiation.active_record") { get inbox_path }
    assert_response :success
    assert_select "a[href=?]", inbox_thread_path(conversation), text: /Latest body/
    assert_equal 1, counts.sum
    assert_equal latest.id, conversation.messages.newest_first.first.id
  end
end
