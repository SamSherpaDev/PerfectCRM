require "test_helper"

class AiCallTest < ActiveSupport::TestCase
  test "expired scope keeps 90 days" do
    fresh = AiCall.create!(purpose: "triage", prompt_version: "v1", status: "ok")
    old = AiCall.create!(purpose: "triage", prompt_version: "v1", status: "ok",
      created_at: 91.days.ago)
    assert_includes AiCall.expired, old
    assert_not_includes AiCall.expired, fresh
  end

  test "prune job deletes only expired rows" do
    AiCall.create!(purpose: "triage", prompt_version: "v1", status: "ok",
      created_at: 91.days.ago)
    keep = AiCall.create!(purpose: "draft_reply", prompt_version: "v1", status: "ok")
    Ai::PruneCallsJob.perform_now
    assert_equal [ keep.id ], AiCall.pluck(:id)
  end

  test "new mail expires the cached summary and suggestion" do
    client = Client.create!(name: "Maya", email: "maya-ai@example.com")
    conversation = Conversation.create!(subject: "Dates", linkable: client,
      last_message_at: Time.current, ai_summary: "• a", ai_summary_at: Time.current,
      ai_suggestion_title: "Call", ai_suggestion_due_on: Date.current + 2)
    conversation.messages.create!(direction: "in", from_address: client.email,
      sent_at: Time.current, text_body: "new mail")
    assert_nil conversation.reload.ai_summary
    assert_nil conversation.reload.ai_suggestion_title
  end
  test "summary preserves substantive leading numbers" do
    assert_equal "• 4 guests confirmed\n• 2026 departure requested\n• Call captain",
      Ai::Summarize.normalize("• 4 guests confirmed\n2. 2026 departure requested\n- Call captain")
  end

  test "stale conversation cannot accept a suggestion twice" do
    client = Client.create!(name: "Traveler")
    conversation = Conversation.create!(linkable: client, ai_suggestion_title: "Call traveler")
    stale = Conversation.find(conversation.id)
    assert_difference "Task.count", 1 do
      assert Ai::Suggest.accept!(conversation)
      assert_nil Ai::Suggest.accept!(stale)
    end
    assert_equal 1, client.activity_events.where("summary LIKE ?", "Accepted AI suggestion:%").count
  end

end
