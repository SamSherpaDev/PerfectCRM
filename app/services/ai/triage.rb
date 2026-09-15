# frozen_string_literal: true

# Inbound triage classification: new_inquiry, returning_client, operator,
# vendor_or_spam, or other, with a one-line reason and a suggested lead
# source. The captain's confirmations are logged for later prompt tuning.
module Ai
  module Triage
    CATEGORIES = %w[new_inquiry returning_client operator vendor_or_spam other].freeze
    SOURCES = %w[google_ads meta_ads website_form email referral manual].freeze

    def self.call(conversation)
      latest = conversation.messages.inbound.oldest_first.limit(6)
      thread = latest.map do |message|
        body = Scrub.scrub(message.text_body.presence ||
          ActionView::Base.full_sanitizer.sanitize(message.html_body.to_s).squish)
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

      conversation.update_columns(ai_triage: parsed[:category], ai_triage_reason: parsed[:reason],
        ai_triage_suggested_source: parsed[:source], ai_triage_at: Time.current,
        ai_triage_confirmed: nil)
      Client::Result.new(text: parsed[:category], status: :ok, ai_call: result.ai_call)
    end

    def self.parse(text)
      json = text.to_s[/\{.*\}/m] || text.to_s
      data = JSON.parse(json)
      category = data["category"].to_s
      category = "other" unless CATEGORIES.include?(category)
      reason = data["reason"].to_s.strip.truncate(140).presence || "Classified by AI."
      source = data["suggested_source"].to_s
      source = nil unless SOURCES.include?(source)
      { category: category, reason: reason, source: source }
    rescue JSON::ParserError
      nil
    end

    def self.confirm!(conversation, category)
      category = category.to_s
      category = "other" unless CATEGORIES.include?(category)
      conversation.update_columns(ai_triage_confirmed: category)
      AiCall.create!(purpose: "triage_confirm", prompt_version: Prompts.version,
        model: Setting.current.ai_model.presence, status: "ok",
        request_redacted: "confirm #{conversation.ai_triage} -> #{category}".truncate(500),
        conversation: conversation)
      category
    end
  end
end
