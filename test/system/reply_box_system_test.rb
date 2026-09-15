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
    assert_equal "Hi Maya", find_field("Subject").value
    assert_includes find_field("Message").value, "Hello Maya"
    assert_includes find_field("Message").value, "[missing: trip]"
    assert_no_overflow("after insert")

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
