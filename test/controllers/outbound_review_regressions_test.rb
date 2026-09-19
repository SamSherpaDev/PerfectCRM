require "test_helper"
require_relative "../support/google_sign_in_test_helper"

class OutboundReviewRegressionsTest < ActionDispatch::IntegrationTest
  include GoogleSignInTestHelper

  setup do
    @client = Client.create!(name: "Maya Gurung", email: "maya@example.com", perfectbook_contact_id: 4242)
    @template = Template.create!(name: "Trip", purpose: "custom", subject: "{{trip}}", body: "{{first_name}}: {{trip}} {{balance_due}}")
    sign_in
  end

  test "merge rejects malformed and multiple addresses with original line numbers" do
    lines = "maya@example.com\na@@example.com\nalice@example.com,bob@example.com\nMaya <a@@example.com>"
    post merge_templates_path, params: { template_id: @template.id, recipients: lines }
    assert_select "[role=alert]", text: /Line 2:.*Line 3:.*Line 4:/m
    assert_select "form[action=?]", group_sends_path, count: 0
    assert_no_difference("Message.count") do
      post group_sends_path, params: { template_id: @template.id, recipients: lines }
    end
  end

  test "departure refill, preview, and send use the chosen booking for owners and strangers" do
    PerfectBook::Departure.create!(perfectbook_id: 7001, trip_name: "October", synced_at: Time.current)
    [ [ 4242, "Maya Gurung", "maya@example.com" ], [ 4243, "Tashi", "tashi@example.com" ] ].each do |id, name, email|
      PerfectBook::Contact.create!(perfectbook_id: id, name: name, email: email, synced_at: Time.current)
      PerfectBook::Booking.create!(perfectbook_id: id, perfectbook_contact_id: id, departure_id: 7001,
        trip_name: "October trek", start_date: "2026-10-01", balance_due_minor: 12300, currency: "USD", synced_at: Time.current)
      PerfectBook::Booking.create!(perfectbook_id: id + 100, perfectbook_contact_id: id, departure_id: 7002,
        trip_name: "May trek", start_date: "2027-05-01", synced_at: Time.current)
    end
    post merge_templates_path, params: { template_id: @template.id, departure_id: 7001, refill: "1", recipients: "old@example.com" }
    assert_select "textarea[name=recipients]", text: /Maya Gurung <maya@example.com>.*Tashi <tashi@example.com>/m
    assert_select "section[aria-label='Merged messages']", text: /October trek.*\$123.00/m
    post group_sends_path, params: { template_id: @template.id, departure_id: 7001, recipients: "maya@example.com\ntashi@example.com" }
    assert_equal [ "October trek", "October trek" ], GroupSend.last.messages.pluck(:subject)
    assert GroupSend.last.messages.all? { |message| message.text_body.include?("$123.00") }
  end

  test "sent draft attachments survive and subsequent edits are preserved" do
    draft = Draft.create!(owner: @client, body: "Saved", template: @template)
    draft.files.attach(io: StringIO.new("saved bytes"), filename: "saved.txt", content_type: "text/plain")
    post client_messages_path(@client), params: { message: { to: @client.email, subject: "Hello", body: "Submitted", template_id: @template.id,
      files: [ fixture_file_upload("test/fixtures/files/sample.txt", "text/plain") ] } }
    message = Message.last
    assert_equal [ "sample.txt", "saved.txt" ], message.files.map { |file| file.filename.to_s }.sort
    draft.update!(body: "Newer words")
    message.mark_sent!
    assert_equal "Newer words", draft.reload.body
    assert_equal "saved bytes", message.files.find { |file| file.filename.to_s == "saved.txt" }.download
  end

  test "sending a new-message draft clears only that submitted draft" do
    draft = Draft.create!(owner: @client, body: "Saved")
    post client_messages_path(@client), params: { message: { to: @client.email, subject: "Hello", body: "Submitted" } }
    Message.last.mark_sent!
    assert_not Draft.exists?(draft.id)
  end

  test "used templates archive and unused templates delete" do
    [ Message, Draft, GroupSend ].each do |type|
      template = @template.dup
      template.save!
      case type.name
      when "Message"
        Outbound::Composer.call(owner: @client, params: { subject: "Hi", body: "Hi", template_id: template.id })
      when "Draft"
        Draft.create!(owner: @client, body: "Hi", template: template)
      when "GroupSend"
        GroupSend.create!(template: template)
      end
      delete template_path(template)
      assert template.reload.archived?
      assert_match(/archived/, flash[:notice])
    end
    delete template_path(@template)
    assert_not Template.exists?(@template.id)
  end

  test "thread recipients and all history pages remain accessible" do
    conversation = @client.conversations.create!(subject_line: "Secondary")
    101.times do |i|
      conversation.messages.create!(direction: "out", status: "sent", subject: "Message #{i}",
        to_addrs: "secondary@example.com", cc_addrs: "cc@example.com", text_body: "Body #{i}", message_id: "<#{i}@example.com>")
    end
    get client_path(@client)
    assert_select "input[name='message[to]'][value='secondary@example.com']"
    assert_select "input[name='message[cc]'][value='cc@example.com']"
    assert_select "a", text: "Load older"
    get client_path(@client), params: { page: 3 }
    assert_select ".timeline", text: /Message 0/
    50.times { |i| @client.conversations.create!(subject_line: "Thread #{i}") }
    get inbox_path, params: { tab: "all" }
    assert_select "a", text: "Load older"
    get inbox_path, params: { page: 2, tab: "all" }
    assert_select "a[href=?]", inbox_thread_path(conversation)
  end

  test "lead conversion transfers threads and keeps both new-message drafts" do
    lead = Lead.create!(name: "Maya", email: @client.email)
    conversation = lead.conversations.create!(subject_line: "Lead thread")
    draft = conversation.create_draft!(owner: lead, body: "Reply")
    new_draft = Draft.create!(owner: lead, body: "Lead new message")
    client_draft = Draft.create!(owner: @client, body: "Client new message")
    assert_equal @client, lead.convert_to_client!
    assert_equal @client, conversation.reload.owner
    assert_equal @client, draft.reload.owner
    assert_equal @client, new_draft.reload.owner
    assert new_draft.conversation.present?
    assert_equal "Client new message", client_draft.reload.body
  end

  test "recipient request fields are redacted" do
    filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
    assert_equal({ "message" => { "to" => "[FILTERED]", "cc" => "[FILTERED]", "bcc" => "[FILTERED]" } },
      filter.filter("message" => { "to" => "a@example.com", "cc" => "b@example.com", "bcc" => "c@example.com" }))
  end
end
