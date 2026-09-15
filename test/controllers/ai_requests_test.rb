require "test_helper"
require_relative "../support/google_sign_in_test_helper"

class AiRequestsTest < ActionDispatch::IntegrationTest
  include GoogleSignInTestHelper

  setup do
    sign_in
    @client = Client.create!(name: "Tashi", email: "tashi-ai@example.com")
    @conversation = Conversation.create!(subject: "Everest dates", linkable: @client,
      last_message_at: Time.current)
    @conversation.messages.create!(direction: "in", from_address: @client.email,
      to_addresses: [ "info@sherpaholidays.com" ], subject: "Everest dates",
      sent_at: Time.current, text_body: "Namaste, we want Everest in May for 4 guests.")
    enable_ai!
  end

  FakeAdapter = Struct.new(:text) do
    def chat(system:, messages:, max_tokens: 10, json_mode: false)
      { text: text, input_tokens: 5, output_tokens: 7, latency_ms: 3 }
    end
  end

  def enable_ai!
    Setting.current.update!(ai_enabled: true, ai_provider: "openai_compatible",
      ai_model: "mini", ai_api_key: "test-key", ai_base_url: "https://api.example.com/v1",
      ai_daily_cost_cap_cents: 10_000, ai_rate_limit_per_minute: 20)
  end

  def stub_adapter(text)
    Ai::Client.stub(:build_adapter, FakeAdapter.new(text)) { yield }
  end

  test "draft reply fills the dashed-edge block and logs the call" do
    stub_adapter("Hi Tashi, May works — here are the next steps.") do
      post ai_conversation_draft_path(@conversation),
        headers: { "Accept" => "text/vnd.turbo-stream.html" }
    end
    assert_response :success
    assert_match "AI draft, yours to edit", response.body
    assert_match "Hi Tashi", response.body
    call = AiCall.order(:created_at).last
    assert_equal "draft_reply", call.purpose
    assert_equal "v1", call.prompt_version
    assert_equal "mini", call.model
    assert_equal "ok", call.status
    assert_equal @conversation.id, call.conversation_id
  end

  test "draft reply never echoes sensitive numbers" do
    @conversation.messages.create!(direction: "in", from_address: @client.email,
      sent_at: Time.current, text_body: "My passport 123456789, please help.")
    stub_adapter("Noted your passport 123456789, Tashi.") do
      post ai_conversation_draft_path(@conversation),
        headers: { "Accept" => "text/vnd.turbo-stream.html" }
    end
    assert_response :success
    assert_no_match "123456789", response.body
  end

  test "summary caches three bullets atop the thread" do
    stub_adapter("• They want Everest in May\n• Party of four\n• Needs dates and price") do
      post ai_conversation_summary_path(@conversation),
        headers: { "Accept" => "text/vnd.turbo-stream.html" }
    end
    assert_response :success
    assert_match "Everest", @conversation.reload.ai_summary
    second_count = AiCall.where(purpose: "summarize_thread").count
    post ai_conversation_summary_path(@conversation),
      headers: { "Accept" => "text/vnd.turbo-stream.html" }
    assert_response :success
    assert_equal second_count, AiCall.where(purpose: "summarize_thread").count,
      "cached summary must not call the provider again"
  end

  test "suggestion accept creates a task, never automatically" do
    stub_adapter('{"title":"Call Tashi about May dates","due_in_days":3,"reason":"Waiting on dates"}') do
      post ai_conversation_suggestion_path(@conversation),
        headers: { "Accept" => "text/vnd.turbo-stream.html" }
    end
    assert_response :success
    assert_equal "Call Tashi about May dates", @conversation.reload.ai_suggestion_title
    assert_equal 0, @client.tasks.count, "suggesting must not create the task"
    post ai_accept_conversation_suggestion_path(@conversation)
    assert_redirected_to inbox_thread_path(@conversation)
    assert_equal 1, @client.tasks.count
    assert_nil @conversation.reload.ai_suggestion_title
  end

  test "triage classifies with reason and logs the confirmation" do
    thread = Conversation.create!(subject: "New trek ask", last_message_at: Time.current)
    thread.messages.create!(direction: "in", from_address: "newbie@example.com",
      sent_at: Time.current, text_body: "Hi, I found you on Google and want Annapurna in October.")
    stub_adapter('{"category":"new_inquiry","reason":"First ask about Annapurna.","suggested_source":"google_ads"}') do
      post ai_conversation_triage_path(thread),
        headers: { "Accept" => "text/vnd.turbo-stream.html" }
    end
    assert_response :success
    assert_equal "new_inquiry", thread.reload.ai_triage
    assert_match "First ask", response.body
    post ai_confirm_conversation_triage_path(thread), params: { category: "new_inquiry" }
    assert_redirected_to inbox_thread_path(thread)
    assert_equal "new_inquiry", thread.reload.ai_triage_confirmed
    assert AiCall.exists?(purpose: "triage_confirm", conversation_id: thread.id)
  end

  test "kill switch falls back without calling the provider" do
    Setting.current.update!(ai_enabled: false)
    Ai::Client.stub(:build_adapter, ->(*) { raise "must not be called" }) do
      post ai_conversation_draft_path(@conversation),
        headers: { "Accept" => "text/vnd.turbo-stream.html" }
    end
    assert_response :success
    assert_match "AI drafts are off", response.body
  end

  test "per-client opt-out falls back without calling the provider" do
    @client.update!(ai_opt_out: true)
    Ai::Client.stub(:build_adapter, ->(*) { raise "must not be called" }) do
      post ai_conversation_draft_path(@conversation),
        headers: { "Accept" => "text/vnd.turbo-stream.html" }
    end
    assert_response :success
    assert_match "AI is off for this client", response.body
  end

  test "daily cost cap stops new calls" do
    Setting.current.update!(ai_daily_cost_cap_cents: 1)
    AiCall.create!(purpose: "draft_reply", prompt_version: "v1", status: "ok", cost_cents: 5)
    Ai::Client.stub(:build_adapter, ->(*) { raise "must not be called" }) do
      post ai_conversation_summary_path(@conversation),
        headers: { "Accept" => "text/vnd.turbo-stream.html" }
    end
    assert_response :success
    assert_match "cost cap", response.body
  end

  test "thread page shows the AI panel and triage classification slot" do
    get inbox_thread_path(@conversation)
    assert_response :success
    assert_select "[data-assist]", minimum: 1
    assert_select "section.ai-draft-card", text: /Draft a reply/
    assert_select "section.ai-summary", text: /Thread summary/
    assert_select "section.ai-suggestion", text: /Suggested next action/
  end

  test "settings saves the provider key and voice guide" do
    patch ai_settings_path, params: { setting: { ai_enabled: "1", ai_provider: "anthropic",
      ai_model: "haiku", ai_api_key: "new-key", ai_voice_guide: "Short and warm.",
      ai_daily_cost_cap_cents: "500", ai_rate_limit_per_minute: "10" } }
    assert_redirected_to edit_settings_path
    settings = Setting.current.reload
    assert settings.ai_enabled?
    assert_equal "anthropic", settings.ai_provider
    assert_equal "new-key", settings.ai_api_key
  end
end
