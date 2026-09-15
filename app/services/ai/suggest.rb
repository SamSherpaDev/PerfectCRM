# frozen_string_literal: true

# One follow-up task proposal with a due date. The captain accepts with one
# tap (which creates a real Task); nothing is created automatically.
module Ai
  module Suggest
    def self.call(conversation)
      thread = Context.thread_text(conversation)
      facts = Context.client_facts(conversation.linkable)
      system, user = Prompts.render(:suggest_next_action, thread: thread, client_facts: facts)
      result = Client.chat(purpose: :suggest_next_action, system: system,
        messages: [ { role: :user, content: user } ], max_tokens: 300,
        json_mode: true, conversation: conversation)
      return result if result.status != :ok || result.text.blank?

      parsed = parse(result.text)
      return Client::Result.new(text: "", status: :error, ai_call: result.ai_call) if parsed.nil?

      title = parsed["title"].to_s.strip.truncate(120)
      days = parsed["due_in_days"].to_i.clamp(1, 14)
      reason = parsed["reason"].to_s.strip.truncate(200)
      due_on = Date.current + days
      conversation.update_columns(ai_suggestion_title: title.presence, ai_suggestion_due_on: due_on,
        ai_suggestion_reason: reason.presence, ai_suggestion_at: Time.current)
      Client::Result.new(text: title, status: :ok, ai_call: result.ai_call)
    end

    def self.parse(text)
      json = text.to_s[/\{.*\}/m] || text.to_s
      data = JSON.parse(json)
      return nil if data["title"].to_s.strip.blank?

      data
    rescue JSON::ParserError
      nil
    end

    def self.accept!(conversation, user: nil)
      title = conversation.ai_suggestion_title.to_s.strip
      return nil if title.blank? || conversation.linkable.nil?

      task = conversation.linkable.tasks.create!(
        title: title, due_on: conversation.ai_suggestion_due_on || Date.current + 3,
        kind: "follow_up", created_by: "captain"
      )
      conversation.linkable.activity_events.create!(
        kind: "task", summary: "Accepted AI suggestion: #{title}",
        occurred_at: Time.current, metadata: { "task_id" => task.id, "ai" => true })
      conversation.update_columns(ai_suggestion_title: nil, ai_suggestion_due_on: nil,
        ai_suggestion_reason: nil, ai_suggestion_at: nil)
      task
    end
  end
end
