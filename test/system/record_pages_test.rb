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

  test "archived client shows only restore" do
    client = Client.create!(name: "Record Archived", email: "archived@example.com")
    client.archive!

    visit client_path(client)
    assert_button "Restore"
    assert_no_link "Edit"
    assert_no_button "Send"
    assert_no_button "Save note"
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
