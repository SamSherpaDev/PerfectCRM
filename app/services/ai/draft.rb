# frozen_string_literal: true

# Approval-only draft reply. Builds from the thread, the linked record, the
# mirrored PerfectBook facts, and the captain's voice; the prompt forbids
# numbers not present in the supplied facts. Returns text the captain edits
# before Send; nothing here ever sends.
module Ai
  module Draft
    def self.call(conversation)
      thread = Context.thread_text(conversation)
      record = conversation.linkable
      facts = Context.client_facts(record)
      bookings = Context.booking_facts(record)
      voice = Context.voice_examples
      guide = Setting.current.ai_voice_guide.to_s.presence || "Short, warm, plain-spoken."
      allowed = Context.allowed_numbers(thread: thread, client_facts: facts, booking_facts: bookings)
      system, user = Prompts.render(:draft_reply, thread: thread, client_facts: facts,
        booking_facts: bookings, voice_examples: voice, voice_guide: guide, allowed_numbers: allowed)
      Client.chat(purpose: :draft_reply, system: system,
        messages: [ { role: :user, content: user } ], max_tokens: 800, conversation: conversation)
    end
  end
end
