# frozen_string_literal: true

# Inbound triage classification: new_inquiry, returning_client, operator,
# vendor_or_spam, or other, with a one-line reason and a suggested lead
# source.
module Ai
  module Triage
    CATEGORIES = %w[new_inquiry returning_client operator vendor_or_spam other].freeze
    SOURCES = %w[google_ads meta_ads website_form email referral manual].freeze

    def self.call(conversation)
      message_ids = conversation.messages.reorder(:id).pluck(:id)
      latest = conversation.messages.inbound.reorder(sent_at: :desc, id: :desc).limit(6).to_a.reverse
      thread = latest.map do |message|
        body = Context.message_body(message)
        "#{message.from_address}: #{body.truncate(800)}"
      end.join("\n\n")
      from = latest.last&.from_address.to_s
      subject = conversation.subject.to_s
      system, user = Prompts.render(:triage, from: from, subject: subject, thread: thread)
      result = Client.chat(purpose: :triage, system: system,
        messages: [ { role: :user, content: user } ], max_tokens: 300,
        json_mode: true, conversation: conversation)
      return result if result.status != :ok || result.text.blank?

      parsed = parse(result.text)
      return Client::Result.new(text: "", status: :error, ai_call: result.ai_call) if parsed.nil?

      conversation.with_lock do
        if conversation.messages.reorder(:id).pluck(:id) == message_ids
          conversation.update_columns(ai_triage: parsed[:category], ai_triage_reason: parsed[:reason],
            ai_triage_suggested_source: parsed[:source], ai_triage_at: Time.current)
        end
      end
      Client::Result.new(text: parsed[:category], status: :ok, ai_call: result.ai_call)
    end

    def self.parse(text)
      data = JSON.parse(text.to_s)
      return nil unless data.is_a?(Hash)
      return nil unless data["category"].is_a?(String)
      return nil unless data["reason"].nil? || data["reason"].is_a?(String)
      return nil unless data["suggested_source"].nil? || data["suggested_source"].is_a?(String)
      category = data["category"].to_s
      category = "other" unless CATEGORIES.include?(category)
      reason = data["reason"].to_s.strip.truncate(140).presence || "Classified by AI."
      source = data["suggested_source"].to_s
      source = nil unless SOURCES.include?(source)
      { category: category, reason: reason, source: source }
    rescue JSON::ParserError
      nil
    end

  end
end
