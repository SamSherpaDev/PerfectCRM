require "application_system_test_case"
require_relative "../support/google_sign_in_test_helper"

# The Copper-shaped record page (docs/DESIGN.md 4.5): Details left, composer
# and one timeline in the middle, Upcoming and Files right; three tabs with
# Thread first on the phone. PARALLEL_WORKERS=1; desktop at 1400x900.
class RecordPagesTest < ApplicationSystemTestCase
  include GoogleSignInTestHelper

  setup do
    OmniAuth.config.mock_auth[:google_oauth2] = OmniAuth::AuthHash.new(
      provider: "google_oauth2", uid: "google-captain",
      extra: { id_token: JWT.encode(@claims, @key, "RS256") }
    )
    Google::Auth::IDTokens.stub(:oidc_key_source, @source) do
      visit "/auth/google_oauth2/callback"
      assert_selector "h1", text: "Today"
    end
    page.current_window.resize_to(1400, 900)
  end

  test "lead page shows three columns with one timeline and no automations" do
    lead = Lead.create!(name: "Record Tashi", email: "tashi@example.com",
      source: "website_form", trip_interest: "Everest", message: "Two of us in May.")
    conversation = lead.conversations.create!(subject_line: "Everest in May")
    conversation.messages.create!(direction: "out", status: "sent",
      subject: "Zephyr check-in 7f3a", to_addrs: "tashi@example.com",
      text_body: "A quick hello.", message_id: "<zephyr-7f3a@example.com>")

    visit lead_path(lead)
    assert_selector "h1", text: "Record Tashi"
    assert_grid_columns(3)
    assert_selector "h2", text: "Details"
    assert_selector "h2", text: "Timeline"
    assert_selector "h2", text: "Upcoming"
    assert_selector "h2", text: "Files"
    assert_button "Send"
    assert_selector "p", text: "Zephyr check-in 7f3a", count: 1
    assert_no_text "Automations"
    assert_no_selector "h2", text: "Automations"
    assert_no_overflow(1400, "lead page")
  end

  test "client page shows three columns with upcoming, files, and trip" do
    client = Client.create!(name: "Record Amara", email: "amara@example.com",
      source: "website", perfectbook_contact_id: 4242)
    client.tasks.create!(title: "Call Amara", due_on: Date.current)
    PerfectBook::Booking.create!(perfectbook_id: 4242, perfectbook_contact_id: 4242,
      ref: "SH-4242", trip_name: "Everest", start_date: Date.current + 20,
      end_date: Date.current + 32, status: "confirmed", total_minor: 370_000,
      paid_minor: 100_000, balance_due_minor: 270_000, synced_at: Time.current)

    visit client_path(client)
    assert_selector "h1", text: "Record Amara"
    assert_grid_columns(3)
    assert_selector "h2", text: "Upcoming"
    assert_text "Call Amara"
    assert_selector "h2", text: "Files"
    assert_selector "h2", text: "Trip in PerfectBook"
    assert_text "SH-4242"
    assert_no_text "Automations"
    assert_no_overflow(1400, "client page")
  end

  test "note saved from the composer lands on the timeline" do
    lead = Lead.create!(name: "Record Note", email: "note@example.com", source: "manual")

    visit lead_path(lead)
    choose "Note", allow_label_click: true
    fill_in "Add a note", with: "Prefers a slow pace"
    click_button "Save note"
    assert_text "Note saved."
    within(".timeline") { assert_text "Prefers a slow pace" }
  end

  test "follow-up completes in place from upcoming" do
    client = Client.create!(name: "Record Task", email: "task@example.com")
    client.tasks.create!(title: "Confirm itinerary", due_on: Date.current)

    visit client_path(client)
    find("button[aria-label='Mark done: Confirm itinerary']").click
    assert_text "Done. Nice."
    within(".timeline") { assert_text "Completed: Confirm itinerary" }
  end

  test "converted lead shows only open client" do
    lead = Lead.create!(name: "Record Converted", source: "manual")
    client = lead.convert_to_client!

    visit lead_path(lead)
    assert_link "Open client", href: client_path(client)
    assert_no_link "Edit"
    assert_no_button "Convert to client"
    assert_no_button "Send"
    assert_no_button "Save note"
  end

  test "archived client retains editing composing notes and follow-ups" do
    client = Client.create!(name: "Record Archived", email: "archived@example.com")
    client.archive!

    visit client_path(client)
    assert_link "Edit", href: edit_client_path(client)
    assert_button "Send"
    fill_in "New follow-up", with: "Call archived client"
    click_button "Add", exact: true
    assert_text "Call archived client"
    choose "Note", allow_label_click: true
    fill_in "Add a note", with: "Archived client called"
    click_button "Save note"
    within(".timeline") { assert_text "Archived client called" }
    find("summary[aria-label='More actions']").click
    assert_button "Restore"
    assert_no_button "Archive client"
  end

  test "phone shows the thread tab first with the docked reply pill" do
    lead = Lead.create!(name: "Record Phone", email: "phone@example.com", source: "manual")
    lead.notes.create!(body: "Called twice")
    conversation = lead.conversations.create!(subject_line: "Hello")
    conversation.messages.create!(direction: "in", from_address: "phone@example.com",
      subject: "Hello", text_body: "Any October dates?", message_id: "<record-phone@example.com>")
    page.current_window.resize_to(390, 844)

    visit lead_path(lead)
    assert_selector ".record-tabs .tab-on", text: "Thread"
    assert_selector ".record-tabs .tab-dot"
    assert_selector ".timeline", visible: true
    assert_selector "#details-heading", visible: false
    assert_selector ".reply-pill", visible: true
    assert_no_overflow(390, "phone thread tab")

    click_button "Details", exact: true
    assert_selector "#details-heading", visible: true
    assert_selector ".timeline", visible: false
  end

  test "nudge follows the recipient and resets the phone tab while deep links still work" do
    owner = Client.create!(name: "Maya Owner", email: "maya@example.com", perfectbook_contact_id: 8101)
    recipient = Client.create!(name: "Pemba Traveler", email: "pemba@example.com", perfectbook_contact_id: 8102)
    [ [ owner, "Owner trip" ], [ recipient, "Recipient trip" ] ].each do |client, trip|
      PerfectBook::Contact.create!(perfectbook_id: client.perfectbook_contact_id,
        name: client.name, email: client.email, synced_at: Time.current)
      PerfectBook::Booking.create!(perfectbook_id: client.perfectbook_contact_id,
        perfectbook_contact_id: client.perfectbook_contact_id, trip_name: trip,
        synced_at: Time.current)
    end
    conversation = owner.conversations.create!(subject_line: "Traveler request")
    conversation.messages.create!(direction: "in", from_address: recipient.email,
      subject: "Traveler request", text_body: "Please follow up",
      message_id: "<traveler-request@example.com>")
    template = Template.create!(name: "Recipient nudge", subject: "About {{trip}}",
      body: "Hi {{first_name}}, about {{trip}}.")
    task = owner.tasks.create!(title: "Nudge traveler", due_on: Date.current, template: template)
    page.current_window.resize_to(390, 844)

    visit client_path(owner)
    click_button "Files & dates"
    assert_selector "#files-heading", visible: true
    visit client_path(owner, template: template.id, task: task.id)
    assert_selector ".record-tabs .tab-on", text: "Thread"
    assert_field "Message", with: "Hi Pemba, about Recipient trip."
    assert_equal recipient.email, find("#message_to", visible: :all).value
    assert_equal "About Recipient trip", find("#message_subject", visible: :all).value
    assert_equal "8102", find("#message_perfectbook_booking_id", visible: :all).value

    visit client_path(owner, anchor: "files-heading")
    assert_selector ".record-tabs .tab-on", text: "Files & dates"
    assert_selector "#files-heading", visible: true
  end

  test "inquiry rows and counts require evidence and describe their source" do
    lead = Lead.create!(name: "Manual inquiry", source: "manual")
    page.current_window.resize_to(390, 844)
    visit lead_path(lead)
    assert_no_selector "#inquiry"
    assert_selector "[data-tab='thread'] .tab-count", text: "0", exact_text: true

    lead.update!(message: "Called about a trek")
    visit lead_path(lead)
    within("#inquiry") { assert_text "Called about a trek" }
    assert_selector "[data-tab='thread'] .tab-count", text: "1", exact_text: true

    lead.update!(message: nil, received_at: Time.current)
    visit lead_path(lead)
    within("#inquiry") do
      assert_text "Inquiry received."
      assert_no_text "Sent the website form"
    end

    lead.update!(source: "website_form")
    visit lead_path(lead)
    within("#inquiry") { assert_text "Sent the website form without a message." }
    assert_selector "[data-tab='thread'] .tab-count", text: "1", exact_text: true
  end

  test "archived leads remain read only" do
    lead = Lead.create!(name: "Archived lead", source: "manual")
    lead.archive!
    visit lead_path(lead)
    assert_button "Restore"
    assert_no_link "Edit"
    assert_no_button "Send"
    assert_no_button "Save note"
    assert_no_field "New follow-up"
  end

  test "files include only owned attachments and holdings with message metadata" do
    client = Client.create!(name: "Files client", email: "files@example.com")
    conversation = client.conversations.create!(subject_line: "Files")
    plain = conversation.messages.create!(direction: "in", text_body: "No files")
    attached = conversation.messages.create!(direction: "in", from_address: client.email,
      text_body: "Large body", held_attachments: [])
    attached.files.attach(io: StringIO.new("file"), filename: "passport.txt",
      content_type: "text/plain", metadata: { sensitive: true })
    held = conversation.messages.create!(direction: "in",
      held_attachments: [ { "filename" => "held.pdf", "status" => "expired", "byte_size" => 42 } ])
    other = Client.create!(name: "Other client")
    other.conversations.create!(subject_line: "Private").messages.create!(direction: "in",
      held_attachments: [ { "filename" => "private.pdf", "status" => "expired" } ])

    loader = Object.new.extend(RecordPage)
    rows = loader.send(:files_for, client)
    assert_equal [ attached.id, held.id ].sort, rows.map { |row| row.message.id }.sort
    assert rows.none? { |row| row.message.id == plain.id }
    rows.each do |row|
      assert_not row.message.has_attribute?(:text_body)
      assert_not row.message.has_attribute?(:html_body)
    end

    visit client_path(client)
    within("section[aria-labelledby='files-heading']") do
      assert_text "passport.txt"
      assert_text "Potentially sensitive"
      assert_text "held.pdf"
      assert_no_text "private.pdf"
      assert_link "Download", href: attachment_path(attached.files.first.id)
    end
  end

  private

  def assert_grid_columns(count)
    columns = page.evaluate_script(
      "getComputedStyle(document.querySelector('.record')).gridTemplateColumns.split(' ').length")
    assert_equal count, columns, "want #{count} record columns"
  end

  def assert_no_overflow(width, context)
    actual = page.evaluate_script("document.documentElement.scrollWidth")
    assert_operator actual, :<=, width, "#{context} overflows a #{width}px viewport (#{actual}px)"
  end
end
