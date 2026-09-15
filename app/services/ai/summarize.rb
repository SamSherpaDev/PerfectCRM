# frozen_string_literal: true

# Three-bullet thread summary, cached per conversation and refreshed when
# new mail arrives (Message clears ai_summary on create).
module Ai
  module Summarize
    def self.call(conversation)
      message_ids = conversation.messages.reorder(:id).pluck(:id)
      thread = Context.thread_text(conversation)
      return Client::Result.new(text: "", status: :off, ai_call: nil) if thread.blank?

      system, user = Prompts.render(:summarize_thread, thread: thread)
      result = Client.chat(purpose: :summarize_thread, system: system,
        messages: [ { role: :user, content: user } ], max_tokens: 300, conversation: conversation)
      if result.status == :ok && result.text.present?
        bullets = normalize(result.text)
        conversation.with_lock do
          if conversation.messages.reorder(:id).pluck(:id) == message_ids
            conversation.update_columns(ai_summary: bullets, ai_summary_at: Time.current)
          end
        end
        Client::Result.new(text: bullets, status: :ok, ai_call: result.ai_call)
      else
        result
      end
    end

    def self.normalize(text)
      lines = text.to_s.lines.map(&:strip).reject(&:blank?).first(3)
      lines = lines.map { |line| line.sub(/\A(?:[-*•]\s*|\d+[.)]\s+)/, "") }.reject(&:blank?)
      lines.first(3).map { |line| "• #{line}" }.join("\n")
    end
  end
end
