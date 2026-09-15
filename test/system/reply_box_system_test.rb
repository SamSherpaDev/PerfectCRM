require "application_system_test_case"
require_relative "../support/google_sign_in_test_helper"

# The captain answers clients from his phone: the docked reply box —
# template chips, draft saving, and Send — must work one-handed at 390px.
class ReplyBoxSystemTest < ApplicationSystemTestCase
  include GoogleSignInTestHelper

  setup do
    @client = Client.create!(name: "Maya Gurung", email: "maya@example.com")
    @template = Template.create!(name: "Quick hello", purpose: "first_reply",
      subject: "Hi {{first_name}}", body: "Hello {{first_name}}, thinking of {{trip}}!")
  end

  test "chip insert, draft save, and send at 390px" do
    sign_in_browser
    page.current_window.resize_to(390, 844)

    visit client_path(@client)
    assert_selector ".reply-box", visible: false
    assert_no_overflow("client thread")

    # The composer hides behind the Reply pill until the captain opens it.
    click_button "Reply"
    assert_selector ".reply-box", visible: true

    # The phone keeps the dock compact: envelope fields hide behind Details.
    assert_selector "#message_to", visible: false
    find(".reply-details > summary").click

    # Recipient chips arrive prefilled from the thread.
    assert_equal "maya@example.com", find_field("To").value

    # One tap on the template chip fills subject and body with live data.
    click_button "Quick hello"
    assert_field "Subject", with: "Hi Maya"
    assert_field "Message", with: "Hello Maya, thinking of [missing: trip]!"
    assert_includes find_field("Message").value, "[missing: trip]"
    assert_no_overflow("after insert")
    capture_outbound_evidence("mobile-template-reply")

    # Save draft persists without sending.
    fill_in "Message", with: "Hello Maya, half written…"
    click_button "Save draft"
    assert_text "Draft saved", wait: 5
    assert_equal 0, Message.count

    # The Send target stays thumb-sized on the phone.
    send_height = page.evaluate_script(
      "document.querySelector('.reply-send').getBoundingClientRect().height")
    assert_operator send_height, :>=, 44, "Send is #{send_height}px tall, want >= 44px"

    # Send queues delivery and shows the sending state on the timeline.
    fill_in "Subject", with: "Hi Maya"
    click_button "Send"
    assert_text "Sending your reply", wait: 5
    assert_selector ".reply-ev", text: /Sending/
    assert_no_overflow("after send")
  end

  test "searched picker uses the resumed draft booking in the inbox" do
    @client.update!(perfectbook_contact_id: 4242)
    [ [ 9001, "October", "2026-10-01" ], [ 9002, "May", "2027-05-01" ] ].each do |id, trip, date|
      PerfectBook::Booking.create!(perfectbook_id: id, perfectbook_contact_id: 4242,
        trip_name: trip, start_date: date, synced_at: Time.current)
    end
    conversation = @client.conversations.create!(subject_line: "Trip")
    conversation.create_draft!(owner: @client, body: "", perfectbook_booking_id: 9001, template: @template)
    sign_in_browser
    page.current_window.resize_to(1400, 1000)
    visit inbox_thread_path(conversation)
    find(".reply-templates > summary").click
    within(".reply-templates") do
      find("input[name=q]").set("Quick hello")
      assert_selector "input[name=q][value='Quick hello']"
      click_button "Insert"
    end
    assert_field "Message", with: "Hello Maya, thinking of October!"
    find("#message_perfectbook_booking_id option[value='9002']").select_option
    fill_in "Message", with: ""
    click_button "Quick hello", match: :first
    assert_field "Message", with: "Hello Maya, thinking of May!"
  end

  test "partial drafts save without send validation" do
    sign_in_browser
    page.current_window.resize_to(1400, 1000)
    visit client_path(@client)
    fill_in "To", with: ""
    fill_in "Subject", with: ""
    fill_in "Message", with: "Half written"
    click_button "Save draft"
    assert_text "Draft saved"
    assert_equal "Half written", Draft.find_by!(owner: @client).body
    fill_in "Message", with: ""
    click_button "Save draft"
    assert_text "Draft cleared"
    assert_not Draft.exists?(owner: @client)
  end

  test "saving attachments clears selections before another save and send" do
    sign_in_browser
    page.current_window.resize_to(1400, 1000)
    visit client_path(@client)
    fill_in "Subject", with: "Attachment"
    fill_in "Message", with: "See attached"
    attach_file "Attachments", Rails.root.join("test/fixtures/files/sample.txt")
    click_button "Save draft"
    assert_selector "[aria-label='Draft attachments'] li", text: "sample.txt", count: 1
    capture_outbound_evidence("saved-attachment")
    assert_equal "", find_field("Attachments").value
    click_button "Save draft"
    assert_text "Draft saved"
    assert_equal 1, Draft.find_by!(owner: @client).files.count
    click_button "Send"
    assert_text "Sending your reply"
    assert_equal [ "sample.txt" ], Message.last.files.map { |file| file.filename.to_s }
  end

  test "reply inserts and booking choices follow the actual recipient" do
    @client.update!(perfectbook_contact_id: 101)
    @client.people.create!(name: "Pemba", email: "pemba@example.com")
    @client.people.create!(name: "Sona", email: "sona@example.com")
    PerfectBook::Contact.create!(perfectbook_id: 102, name: "Pemba", email: "pemba@example.com", synced_at: Time.current)
    [ [ 501, 101, "Maya trek" ], [ 502, 102, "Pemba trek" ], [ 503, 102, "Pemba later trek" ] ].each do |id, contact, trip|
      PerfectBook::Booking.create!(perfectbook_id: id, perfectbook_contact_id: contact,
        trip_name: trip, balance_due_minor: id * 100, invoice_number: "INV-#{id}", synced_at: Time.current)
    end
    @template.update!(body: "{{full_name}} {{trip}} {{balance_due}} {{invoice_number}}")
    group = GroupSend.create!(template: @template, total_count: 1)
    message = Outbound::Composer.call(owner: @client, group_send: group,
      params: { to: "pemba@example.com", subject: "Pemba trip", body: "Hello" })
    sign_in_browser
    page.current_window.resize_to(1400, 1000)
    [ inbox_thread_path(message.conversation), client_path(@client) ].each do |path|
      visit path
      assert_field "To", with: "pemba@example.com"
      assert_select "Placeholders fill from", options: [ "Pemba later trek · INV-503", "Pemba trek · INV-502" ]
      click_button "Quick hello", match: :first
      assert_field "Message", with: "Pemba Pemba later trek $503.00 INV-503"
      find("#message_perfectbook_booking_id option[value='502']").select_option
      fill_in "Message", with: ""
      find(".reply-templates > summary").click
      within(".reply-templates") { click_button "Insert" }
      assert_field "Message", with: "Pemba Pemba trek $502.00 INV-502"
      fill_in "To", with: "sona@example.com"
      fill_in "Message", with: ""
      click_button "Quick hello", match: :first
      assert_field "Message", with: "Sona Maya trek $501.00 INV-501"
      assert_text "Booking reference: Maya Gurung's booking."
      capture_outbound_evidence("recipient-booking-fallback")
    end
  end

  test "invalid group lines block sending and corrected names stay personal" do
    sign_in_browser
    page.current_window.resize_to(390, 844)
    visit merge_templates_path
    select "Quick hello", from: "Template"
    fill_in "Recipients", with: "Maya <family@example.com>\nwrong@@example.com\na@example.com, b@example.com"
    click_button "Preview merge"
    within("[aria-label='Recipient problems']") do
      assert_text "Line 2:"
      assert_text "Line 3:"
      assert_text "wrong@@example.com"
    end
    assert_no_button "Send 1 personal emails"
    assert_equal 0, GroupSend.count
    capture_outbound_evidence("group-invalid-mobile")
    fill_in "Recipients", with: "Maya <family@example.com>\nPemba <family@example.com>\nstranger@example.com"
    click_button "Preview merge"
    assert_text "Hello Maya"
    assert_text "Hello Pemba"
    assert_text "Missing: first name"
    assert_text "Missing: trip"
    click_button "Send 3 personal emails"
    assert_current_path %r{/group_sends/\d+}
    assert_selector "h1", text: "Send summary"
    assert_equal 3, Message.count
    assert_equal [ "Hi Maya", "Hi Pemba", "Hi [missing: first_name]" ], Message.order(:id).pluck(:subject)
    capture_outbound_evidence("group-summary-mobile")
    message = Message.last
    message.mark_failed!("SMTP unavailable")
    visit group_send_path(message.group_send)
    click_button "Retry"
    assert_no_button "Retry"
    assert_equal "queued", message.reload.status
    assert_equal 3, Message.count
  end

  test "rejected older and new thread sends preserve fields and attachments" do
    older = @client.conversations.create!(subject_line: "Older", last_message_at: 2.days.ago)
    newer = @client.conversations.create!(subject_line: "Newer", last_message_at: 1.day.ago)
    newer.create_draft!(owner: @client, subject: "Other subject", body: "Other words")
    sign_in_browser
    page.current_window.resize_to(1400, 1000)
    [ inbox_thread_path(older), client_path(@client, new_thread: 1) ].each_with_index do |path, index|
      visit path
      fill_in "To", with: "secondary@example.com"
      fill_in "Subject", with: "Correct this reply"
      fill_in "Message", with: "  "
      attach_file "Attachments", Rails.root.join("test/fixtures/files/sample.txt")
      click_button "Send"
      assert_text "Could not send"
      assert_field "To", with: "secondary@example.com"
      assert_field "Subject", with: "Correct this reply"
      assert_selector "[aria-label='Draft attachments'] li", text: "sample.txt"
      assert_current_path path
      assert_equal 0, Message.count
      capture_outbound_evidence("validation-recovery-#{index}")
    end
    assert_equal "Other words", newer.reload.draft.body
  end

  test "duplicate gets a free position and can move up" do
    Template.create!(name: "Second", purpose: @template.purpose, body: "Hi", position: @template.position + 1)
    sign_in_browser
    visit templates_path
    within("[aria-label='Actions for Quick hello']") { click_button "Duplicate" }
    assert_text "duplicated"
    copy = Template.order(:id).last
    assert_equal Template.where.not(id: copy.id).maximum(:position) + 1, copy.position
    visit templates_path
    before = copy.position
    click_button "Move #{copy.name} up"
    assert_selector "section li:nth-child(2) a", text: copy.name
    assert_operator copy.reload.position, :<, before
  end

  test "departure selection loads mirrored travelers and live trip values" do
    PerfectBook::Departure.create!(perfectbook_id: 7001, trip_name: "Annapurna", label: "May 2027", synced_at: Time.current)
    PerfectBook::Contact.create!(perfectbook_id: 4242, name: "Maya Gurung", email: @client.email, synced_at: Time.current)
    PerfectBook::Booking.create!(perfectbook_id: 9002, perfectbook_contact_id: 4242,
      departure_id: 7001, trip_name: "Annapurna", synced_at: Time.current)
    sign_in_browser
    page.current_window.resize_to(390, 844)
    visit merge_templates_path
    select "Annapurna · May 2027", from: "Departure travelers"
    assert_field "Recipients", with: "Maya Gurung <maya@example.com>"
    assert_text "Hello Maya, thinking of Annapurna!"
    capture_outbound_evidence("departure-merge-mobile")
    click_button "Send 1 personal emails"
    assert_selector "h1", text: "Send summary"
    assert_equal "Hello Maya, thinking of Annapurna!", Message.last.text_body
    assert_equal @client, Message.last.owner
  end

  def capture_outbound_evidence(name)
    return if ENV["OUTBOUND_EVIDENCE_DIR"].blank?

    page.save_screenshot(File.join(ENV.fetch("OUTBOUND_EVIDENCE_DIR"), "#{name}.png"))
  end

  test "validation recovery preserves selected booking for template inserts" do
    @client.update!(perfectbook_contact_id: 4242)
    [ [ 9001, "October", "2026-10-01", 12300 ], [ 9002, "May", "2027-05-01", 45600 ] ].each do |id, trip, date, balance|
      PerfectBook::Booking.create!(perfectbook_id: id, perfectbook_contact_id: 4242,
        trip_name: trip, start_date: date, balance_due_minor: balance, synced_at: Time.current)
    end
    @template.update!(body: "{{trip}} {{balance_due}}")
    sign_in_browser
    page.current_window.resize_to(1400, 1000)
    visit client_path(@client, new_thread: 1)
    [ [ 9001, "October $123.00" ], [ 9002, "May $456.00" ] ].each do |id, expected|
      find("#message_perfectbook_booking_id option[value='#{id}']").select_option
      fill_in "Subject", with: "Booking question"
      fill_in "Message", with: "  "
      click_button "Send"
      assert_text "Could not send"
      assert_equal id.to_s, find_field("Placeholders fill from").value
      assert_equal id, Draft.find_by!(owner: @client, conversation_id: nil).perfectbook_booking_id
      fill_in "Message", with: ""
      click_button "Quick hello", match: :first
      assert_field "Message", with: expected
    end
    assert_equal 0, Message.count
  end

  private

  def sign_in_browser
    OmniAuth.config.mock_auth[:google_oauth2] = OmniAuth::AuthHash.new(
      provider: "google_oauth2", uid: "google-captain",
      extra: { id_token: JWT.encode(@claims, @key, "RS256") }
    )
    Google::Auth::IDTokens.stub(:oidc_key_source, @source) do
      visit "/auth/google_oauth2/callback"
      assert_selector "h1", text: "Today"
    end
  end


  def assert_no_overflow(context)
    width = page.evaluate_script("document.documentElement.scrollWidth")
    assert_operator width, :<=, 390, "#{context} overflows a 390px viewport (#{width}px)"
  end
end
