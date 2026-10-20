require "application_system_test_case"
require_relative "../support/google_sign_in_test_helper"

class AiAssistSystemTest < ApplicationSystemTestCase
  include GoogleSignInTestHelper

  setup do
    @previous_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
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

  teardown { Rails.cache = @previous_cache }

  test "thread page hides the AI panel at 390px while keeping the thread and reply box usable" do
    visit inbox_thread_path(@conversation)
    assert_selector "h1", text: "Everest dates"
    assert_no_selector "[data-assist]"
    assert_no_selector "section.ai-draft-card"
    assert_no_selector "section.ai-summary"
    assert_no_selector "section.ai-suggestion"
    assert_selector ".reply-pill", text: "Reply"
    width = page.evaluate_script("document.documentElement.scrollWidth")
    assert_operator width, :<=, 390, "thread page overflows 390px (#{width}px)"
  end

  test "triage card hides the AI classification slot at 390px" do
    visit inbox_thread_path(@triage)
    assert_selector ".triage-card", text: /Suggested client/
    assert_no_selector ".ai-triage"
    assert_no_button "Classify with AI"
    width = page.evaluate_script("document.documentElement.scrollWidth")
    assert_operator width, :<=, 390, "triage card overflows 390px (#{width}px)"
  end
end
