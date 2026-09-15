require "application_system_test_case"
require_relative "../support/google_sign_in_test_helper"

class InboxSystemTest < ApplicationSystemTestCase
  include GoogleSignInTestHelper

  setup do
    @client = Client.create!(name: "Tashi", email: "tashi@example.com")
    @conversation = Conversation.create!(subject: "Everest dates", linkable: @client, last_message_at: Time.current)
    @conversation.messages.create!(direction: "out", from_address: "info@sherpaholidays.com",
      to_addresses: [ "tashi@example.com" ], subject: "Re: Everest dates",
      sent_at: 1.hour.ago, text_body: "Tashi, May works — sending options.")
    @conversation.messages.create!(direction: "in", from_address: "tashi@example.com",
      to_addresses: [ "info@sherpaholidays.com" ], subject: "Everest dates",
      sent_at: Time.current, text_body: "Namaste, we want Everest in May.")
  end

  test "inbox tabs and thread view fit a 390px phone" do
    OmniAuth.config.mock_auth[:google_oauth2] = OmniAuth::AuthHash.new(
      provider: "google_oauth2", uid: "google-captain",
      extra: { id_token: JWT.encode(@claims, @key, "RS256") }
    )
    Google::Auth::IDTokens.stub(:oidc_key_source, @source) do
      visit "/auth/google_oauth2/callback"
      assert_selector "h1", text: "Today"
    end
    page.current_window.resize_to(390, 844)

    visit inbox_path
    assert_selector "h1", text: "Inbox"
    fixed_bars = page.evaluate_script("Array.from(document.querySelectorAll('nav')).filter(nav => getComputedStyle(nav).position === 'fixed' && getComputedStyle(nav).bottom === '0px').length")
    assert_equal 1, fixed_bars
    assert_selector "nav.tabs a", text: /Waiting on you/
    assert_selector "nav.tabs a", text: /Triage/
    assert_selector "nav.tabbar a", text: /Inbox/
    assert_selector "a", text: /Everest dates/
    width = page.evaluate_script("document.documentElement.scrollWidth")
    assert_operator width, :<=, 390, "inbox overflows 390px (#{width}px)"

    click_link "Everest dates", match: :first
    assert_selector "h1", text: "Everest dates"
    assert_selector "a", text: "Inbox"
    assert_selector "a[href='#thread-newest']", text: /Jump to newest/
    assert_selector "article.stone-in", minimum: 1
    assert_selector "article.stone-out", minimum: 1
    assert_selector "nav.tabbar a", text: /Inbox/
    width = page.evaluate_script("document.documentElement.scrollWidth")
    assert_operator width, :<=, 390, "thread overflows 390px (#{width}px)"
    jump = find("a[href='#thread-newest']")
    jump.scroll_to(:center)
    assert page.evaluate_script("((link) => { const rect = link.getBoundingClientRect(); return link.contains(document.elementFromPoint(rect.x + rect.width / 2, rect.y + rect.height / 2)); })(document.querySelector('a[href=\"#thread-newest\"]'))")
    jump.click
    19.times do |index|
      @conversation.messages.create!(direction: "in", from_address: @client.email,
        sent_at: (index + 2).hours.ago, text_body: "Older message #{index}")
    end
    visit client_path(@client)
    click_link "Load older"
    assert_text "Older message 18"
    assert_no_text "Namaste, we want Everest in May."
    click_link "Jump to newest ↑"
    assert_text "Namaste, we want Everest in May."
    assert_equal "mail_page=1", URI.parse(page.current_url).query
  end

  test "triage thread offers link, create, and ignore" do
    triage = Conversation.create!(subject: "New ask", last_message_at: Time.current)
    triage.messages.create!(direction: "in", from_address: "newbie@example.com",
      to_addresses: [ "info@sherpaholidays.com" ], subject: "New ask",
      sent_at: Time.current, text_body: "Hello")
    OmniAuth.config.mock_auth[:google_oauth2] = OmniAuth::AuthHash.new(
      provider: "google_oauth2", uid: "google-captain",
      extra: { id_token: JWT.encode(@claims, @key, "RS256") }
    )
    Google::Auth::IDTokens.stub(:oidc_key_source, @source) do
      visit "/auth/google_oauth2/callback"
    end
    visit "/inbox/#{triage.id}"
    assert_text "Suggested client"
    assert_button "Create client"
    assert_button "Create lead"
    assert_button "Create organization"
    assert_button "Ignore sender"
  end
end
