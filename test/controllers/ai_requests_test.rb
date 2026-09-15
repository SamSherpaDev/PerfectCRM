require "test_helper"
require_relative "../support/google_sign_in_test_helper"

class AiRequestsTest < ActionDispatch::IntegrationTest
  include GoogleSignInTestHelper

  setup do
    @previous_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    sign_in
    @client = Client.create!(name: "Tashi", email: "tashi-ai@example.com")
    @conversation = Conversation.create!(subject: "Everest dates", linkable: @client,
      last_message_at: Time.current)
    @conversation.messages.create!(direction: "in", from_address: @client.email,
      to_addresses: [ "info@sherpaholidays.com" ], subject: "Everest dates",
      sent_at: Time.current, text_body: "Namaste, we want Everest in May for 4 guests.")
    enable_ai!
  end

  teardown { Rails.cache = @previous_cache }

  FakeAdapter = Struct.new(:text) do
    def chat(system:, messages:, max_tokens: 10, json_mode: false)
      { text: text, input_tokens: 5, output_tokens: 7, latency_ms: 3 }
    end
  end

  def enable_ai!
    Setting.current.update!(ai_enabled: true,
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
    post ai_accept_conversation_suggestion_path(@conversation), params: { suggestion_version: @conversation.ai_suggestion_version }
    assert_redirected_to inbox_thread_path(@conversation)
    assert_equal 1, @client.tasks.count
    assert_nil @conversation.reload.ai_suggestion_title
  end

  test "triage classifies with reason for manual actions" do
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
    AiCall.create!(purpose: "draft_reply", prompt_version: "v1", status: "ok", cost_micro_cents: 5_000_000)
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
    patch ai_settings_path, params: { setting: { ai_enabled: "1", ai_base_url: "https://openrouter.ai/api/v1",
      ai_model: "haiku", ai_api_key: "new-key", ai_voice_guide: "Short and warm.",
      ai_daily_cost_cap_cents: "500", ai_rate_limit_per_minute: "10" } }
    assert_redirected_to edit_settings_path
    settings = Setting.current.reload
    assert settings.ai_enabled?
    assert_equal "https://openrouter.ai/api/v1", settings.ai_base_url
    assert_equal "new-key", settings.ai_api_key
  end
  test "new settings enable AI and missing credentials explain setup" do
    assert Setting.new.ai_enabled?
    Setting.current.update!(ai_api_key: nil)
    get inbox_thread_path(@conversation)
    assert_select "[role=status]", text: "Add a provider key in Settings to enable drafts"
    assert_no_difference "AiCall.count" do
      post ai_conversation_draft_path(@conversation), headers: { "Accept" => "text/vnd.turbo-stream.html" }
    end
    assert_match "Add a provider key in Settings to enable drafts", response.body
  end

  test "converted lead opt-outs protect both new and existing clients" do
    [ false, true ].each do |returning|
      email = "conversion-#{returning}@example.com"
      Client.create!(name: "Returning", email: email) if returning
      lead = Lead.create!(name: "Protected", email: email, ai_opt_out: true)
      thread = Conversation.create!(linkable: lead)
      thread.messages.create!(direction: "in", text_body: "Private inquiry")
      post convert_lead_path(lead)
      assert lead.reload.converted_client.ai_opt_out?
      assert_no_difference "AiCall.count" do
        post ai_conversation_draft_path(thread), headers: { "Accept" => "text/vnd.turbo-stream.html" }
      end
      assert_match "AI is off for this client", response.body
    end
  end

  test "written birthdays are scrubbed in provider input logs and output" do
    @conversation.messages.create!(direction: "in", text_body: "Date of birth: 14 May 1990")
    adapter = Object.new
    adapter.define_singleton_method(:chat) do |**args|
      raise "birthday leaked" if args[:messages].any? { |row| row[:content].include?("14 May 1990") }
      { text: "Date of birth: May 14, 1990", input_tokens: 1000, output_tokens: 300 }
    end
    Ai::Client.stub(:build_adapter, adapter) do
      post ai_conversation_draft_path(@conversation), headers: { "Accept" => "text/vnd.turbo-stream.html" }
    end
    call = AiCall.order(:id).last
    assert_equal "ok", call.status
    assert_no_match "1990", call.request_redacted
    assert_no_match "1990", call.response_redacted
    assert_no_match "1990", response.body
    assert_equal 330_000, call.cost_micro_cents
  end

  test "provider receives recent messages in chronological order and currency units" do
    @client.update!(perfectbook_contact_id: 789)
    PerfectBook::Booking.create!(perfectbook_id: 789, perfectbook_contact_id: 789,
      balance_due_minor: 12500, currency: "USD", synced_at: Time.current)
    @conversation.messages.delete_all
    14.times do |i|
      @conversation.messages.create!(direction: "in", sent_at: Time.current.beginning_of_day,
        text_body: "Request #{i}", from_address: "person#{i}@example.com")
    end
    captured = []
    adapter = Object.new
    adapter.define_singleton_method(:chat) do |**args|
      captured << args[:messages].first[:content]
      { text: '{"category":"other","reason":"Review"}', input_tokens: 1, output_tokens: 1 }
    end
    Ai::Client.stub(:build_adapter, adapter) do
      post ai_conversation_draft_path(@conversation), headers: { "Accept" => "text/vnd.turbo-stream.html" }
      post ai_conversation_triage_path(@conversation), headers: { "Accept" => "text/vnd.turbo-stream.html" }
    end
    assert_equal (2..13).to_a, captured.first.scan(/Request (\d+)/).flatten.map(&:to_i)
    assert_includes captured.first, "Balance: USD 125.00"
    assert_equal (8..13).to_a, captured.last.scan(/Request (\d+)/).flatten.map(&:to_i)
    assert_includes captured.last, "From: person13@example.com"
  end

  test "mail arriving during generation prevents publishing obsolete caches" do
    [ ai_conversation_summary_path(@conversation), ai_conversation_suggestion_path(@conversation) ].each do |path|
      thread = @conversation
      adapter = Object.new
      adapter.define_singleton_method(:chat) do |**_args|
        thread.messages.create!(direction: "in", text_body: "Actually October", sent_at: Time.current)
        { text: '{"title":"Ask about May","due_in_days":3}', input_tokens: 1, output_tokens: 1 }
      end
      Ai::Client.stub(:build_adapter, adapter) do
        post path, headers: { "Accept" => "text/vnd.turbo-stream.html" }
      end
      assert_nil @conversation.reload.ai_summary
      assert_nil @conversation.ai_suggestion_title
    end
  end

  test "short calls accumulate toward the daily cap" do
    Setting.current.update!(ai_daily_cost_cap_cents: 1)
    adapter = Object.new
    adapter.define_singleton_method(:chat) do |**_args|
      { text: "Draft", input_tokens: 1000, output_tokens: 300 }
    end
    Ai::Client.stub(:build_adapter, adapter) do
      4.times do
        post ai_conversation_draft_path(@conversation), headers: { "Accept" => "text/vnd.turbo-stream.html" }
      end
      assert_equal 1.32.to_d, AiCall.daily_cost_cents
      assert_no_difference "AiCall.count" do
        post ai_conversation_draft_path(@conversation), headers: { "Accept" => "text/vnd.turbo-stream.html" }
      end
      assert_match "cost cap", response.body
    end
  end

  test "review multiline identity values never reach provider or logs" do
    body = "Date of birth:\n14 May 1990\nPassport:\nX1234567"
    @conversation.messages.create!(direction: "in", text_body: body)
    captured = []
    adapter = Object.new
    adapter.define_singleton_method(:chat) do |**args|
      captured << args[:messages].first[:content]
      { text: body, input_tokens: 1, output_tokens: 1 }
    end
    Ai::Client.stub(:build_adapter, adapter) do
      post ai_conversation_draft_path(@conversation), headers: { "Accept" => "text/vnd.turbo-stream.html" }
    end
    assert_response :success
    [ captured.first, response.body, AiCall.last.request_redacted, AiCall.last.response_redacted ].each do |text|
      assert_no_match /14 May 1990|X1234567/, text
    end
  end

  test "review stale acceptance cannot create an unseen suggestion" do
    stub_adapter('{"title":"Call about May","due_in_days":3,"reason":"Review dates"}') do
      post ai_conversation_suggestion_path(@conversation), headers: { "Accept" => "text/vnd.turbo-stream.html" }
    end
    displayed_version = Nokogiri::HTML(response.body).at_css('input[name="suggestion_version"]')&.[]("value")
    travel 1.second do
      stub_adapter('{"title":"Call about October","due_in_days":4,"reason":"Changed dates"}') do
        post ai_conversation_suggestion_path(@conversation), headers: { "Accept" => "text/vnd.turbo-stream.html" }
      end
    end
    current_version = Nokogiri::HTML(response.body).at_css('input[name="suggestion_version"]')&.[]("value")
    assert_no_difference "Task.count" do
      post ai_accept_conversation_suggestion_path(@conversation), params: { suggestion_version: displayed_version }
    end
    assert_equal "Call about October", @conversation.reload.ai_suggestion_title
    assert_difference "Task.count", 1 do
      post ai_accept_conversation_suggestion_path(@conversation), params: { suggestion_version: current_version }
    end
    assert_equal "Call about October", @client.tasks.last.title
  end

  test "review unexpected provider JSON renders fallback" do
    [ "null", "[]", '[{"title":"Call client"}]', '{"title":"Call client","due_in_days":{}}',
      '{"title":[],"due_in_days":3}', '{"category":{},"reason":[]}' ].each do |payload|
      [ ai_conversation_suggestion_path(@conversation), ai_conversation_triage_path(@conversation) ].each do |path|
        Rails.cache.clear
        stub_adapter(payload) do
          post path, headers: { "Accept" => "text/vnd.turbo-stream.html" }
        end
        assert_response :success
        assert_match "AI could not finish", response.body
      end
    end
  end

  test "HTML identity blocks stay redacted in all AI thread inputs" do
    [ "<div>Date of birth</div><div>14 May 1990</div>",
      "<p>Date of <strong>birth</strong><br>14 May 1990</p>",
      "<table><tr><td>Date of birth</td><td>14 May 1990</td></tr></table>",
      "<div>Date of birth</div><div>14&nbsp;May&nbsp;1990</div>" ].each do |html|
      @conversation.messages.delete_all
      @conversation.messages.create!(direction: "in", html_body: html + "<p>Everest in October</p>")
      captured = []
      adapter = Object.new
      adapter.define_singleton_method(:chat) do |**args|
        captured << args[:messages].first[:content]
        { text: '{"category":"new_inquiry","reason":"Trip request"}', input_tokens: 1, output_tokens: 1 }
      end
      Ai::Client.stub(:build_adapter, adapter) do
        [ ai_conversation_draft_path(@conversation), ai_conversation_summary_path(@conversation),
          ai_conversation_triage_path(@conversation) ].each do |path|
          post path, headers: { "Accept" => "text/vnd.turbo-stream.html" }
          assert_response :success
          assert_no_match /1990/, AiCall.last.request_redacted
        end
      end
      assert_equal 3, captured.size
      captured.each do |input|
        assert_no_match /1990/, input
        assert_includes input, "[redacted]"
        assert_includes input, "Everest in October"
      end
    end
  end

  test "new mail clears triage and offers classification again" do
    @conversation.update!(linkable: nil)
    stub_adapter('{"category":"other","reason":"Ambiguous","suggested_source":"email"}') do
      post ai_conversation_triage_path(@conversation), headers: { "Accept" => "text/vnd.turbo-stream.html" }
    end
    assert_equal "other", @conversation.reload.ai_triage
    @conversation.messages.create!(direction: "in", text_body: "I want an Everest trip")
    assert_nil @conversation.reload.ai_triage
    assert_nil @conversation.ai_triage_reason
    assert_nil @conversation.ai_triage_suggested_source
    assert_nil @conversation.ai_triage_at
    get inbox_thread_path(@conversation)
    assert_select "form[action=?]", ai_conversation_triage_path(@conversation)
  end

  test "new mail prevents in-flight triage from publishing stale classification" do
    thread = @conversation
    adapter = Object.new
    adapter.define_singleton_method(:chat) do |**_args|
      thread.messages.create!(direction: "in", text_body: "I want an Everest trip")
      { text: '{"category":"other","reason":"Ambiguous"}', input_tokens: 1, output_tokens: 1 }
    end
    Ai::Client.stub(:build_adapter, adapter) do
      post ai_conversation_triage_path(@conversation), headers: { "Accept" => "text/vnd.turbo-stream.html" }
    end
    assert_response :success
    assert_nil @conversation.reload.ai_triage
    assert_nil @conversation.ai_triage_at
    assert_match "Classify with AI", response.body
  end

  test "unlinked proposals require linking before acceptance is offered" do
    @conversation.update!(linkable: nil)
    get inbox_thread_path(@conversation)
    assert_select ".ai-suggestion", text: /Link this thread to a client, lead, or organization before accepting a suggestion/
    stub_adapter('{"title":"Call about dates","due_in_days":3,"reason":"Confirm plans"}') do
      post ai_conversation_suggestion_path(@conversation), headers: { "Accept" => "text/vnd.turbo-stream.html" }
    end
    assert_response :success
    assert_select "form[action=?]", ai_accept_conversation_suggestion_path(@conversation), count: 0
    assert_select ".ai-suggestion", text: /Call about dates/
    assert_select ".ai-suggestion", text: /Link this thread to a client, lead, or organization before accepting a suggestion/
    post link_conversation_path(@conversation), params: { linkable_type: "Client", linkable_id: @client.id }
    follow_redirect!
    assert_select "form[action=?]", ai_accept_conversation_suggestion_path(@conversation), count: 1
    version = Nokogiri::HTML(response.body).at_css('input[name="suggestion_version"]')["value"]
    assert_difference "Task.count", 1 do
      post ai_accept_conversation_suggestion_path(@conversation), params: { suggestion_version: version }
    end
    assert_equal "Call about dates", @client.tasks.last.title
  end
  test "blank AI limits render validation feedback with automation activity" do
    @client.activity_events.create!(kind: "automation", summary: "Website inquiry received", occurred_at: Time.current)
    [ :ai_daily_cost_cap_cents, :ai_rate_limit_per_minute ].each do |limit|
      saved_value = Setting.current.public_send(limit)
      patch ai_settings_path, params: { setting: { limit => "" } }
      assert_response :unprocessable_entity
      assert_select "input[name=?]", "setting[#{limit}]" do |fields|
        assert fields.first["value"].blank?
      end
      assert_match "is not a number", response.body
      assert_select "li", text: /Website inquiry received/
      assert_equal saved_value, Setting.current.public_send(limit)
    end
  end
end
