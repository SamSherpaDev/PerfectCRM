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
    OmniAuth.config.mock_auth[:google_oauth2] = OmniAuth::AuthHash.new(
      provider: "google_oauth2", uid: "google-captain",
      extra: { id_token: JWT.encode(@claims, @key, "RS256") }
    )
    Google::Auth::IDTokens.stub(:oidc_key_source, @source) do
      visit "/auth/google_oauth2/callback"
      assert_selector "h1", text: "Today"
    end
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

  private

  def assert_no_overflow(context)
    width = page.evaluate_script("document.documentElement.scrollWidth")
    assert_operator width, :<=, 390, "#{context} overflows a 390px viewport (#{width}px)"
  end
end
