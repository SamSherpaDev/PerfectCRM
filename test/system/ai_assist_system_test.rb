require "application_system_test_case"
require_relative "../support/google_sign_in_test_helper"

class AiAssistSystemTest < ApplicationSystemTestCase
  include GoogleSignInTestHelper

  setup do
    @client = Client.create!(name: "Tashi", email: "tashi-ai-sys@example.com")
    @conversation = Conversation.create!(subject: "Everest dates", linkable: @client,
      last_message_at: Time.current)
    @conversation.messages.create!(direction: "in", from_address: @client.email,
      to_addresses: [ "info@sherpaholidays.com" ], subject: "Everest dates",
      sent_at: Time.current, text_body: "Namaste, we want Everest in May.")
    @triage = Conversation.create!(subject: "New trek ask", last_message_at: Time.current)
    @triage.messages.create!(direction: "in", from_address: "newbie-sys@example.com",
      to_addresses: [ "info@sherpaholidays.com" ], subject: "New trek ask",
      sent_at: Time.current, text_body: "Hi, I found you online and want Annapurna.")
    OmniAuth.config.mock_auth[:google_oauth2] = OmniAuth::AuthHash.new(
      provider: "google_oauth2", uid: "google-captain",
      extra: { id_token: JWT.encode(@claims, @key, "RS256") }
    )
    Google::Auth::IDTokens.stub(:oidc_key_source, @source) do
      visit "/auth/google_oauth2/callback"
      assert_selector "h1", text: "Today"
    end
    page.current_window.resize_to(390, 844)
  end

  test "draft flow shows the AI panel and fallback at 390px" do
    visit inbox_thread_path(@conversation)
    assert_selector "h1", text: "Everest dates"
    assert_selector "[data-assist]", minimum: 1
    assert_selector "section.ai-draft-card", text: /Draft a reply/
    assert_selector "section.ai-summary", text: /Thread summary/
    assert_selector "section.ai-suggestion", text: /Suggested next action/
    click_button "Draft a reply", match: :first
    assert_text "AI drafts are off"
    assert_text "Nothing sends by itself"
    width = page.evaluate_script("document.documentElement.scrollWidth")
    assert_operator width, :<=, 390, "AI panel overflows 390px (#{width}px)"
  end

  test "triage card carries the AI classification slot at 390px" do
    visit inbox_thread_path(@triage)
    assert_selector ".triage-card", text: /Suggested client/
    assert_selector ".ai-triage", text: /Classify with AI/
    click_button "Classify with AI"
    assert_text "AI drafts are off"
    width = page.evaluate_script("document.documentElement.scrollWidth")
    assert_operator width, :<=, 390, "triage card overflows 390px (#{width}px)"
  end
end
