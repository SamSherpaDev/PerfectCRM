# frozen_string_literal: true

# Provider-neutral entry point. One interface (chat completion with a system
# prompt, messages, max tokens, JSON mode); the captain picks the provider
# and model in Settings. Every call is logged to ai_calls with the prompt
# version, token counts, a cost estimate, latency, status, and the redacted
# request/response for review.
#
# Zero-retention posture: callers pass only message text and CRM facts.
# Attachments, document bytes, and PDF titles never reach this layer.
module Ai
  class Client
    Result = Struct.new(:text, :status, :ai_call, keyword_init: true)

    def self.over_daily_cap?(settings = Setting.current)
      cap = settings.ai_daily_cost_cap_cents.to_i
      cap.positive? && AiCall.daily_cost_cents >= cap
    end

    def self.chat(purpose:, system:, messages:, max_tokens: 800, json_mode: false, conversation: nil)
      settings = Setting.current
      version = Prompts.version
      scrubbed_system = Scrub.scrub(system)
      scrubbed_messages = messages.map { |row| { role: row[:role], content: Scrub.scrub(row[:content].to_s) } }
      request_preview = ([ scrubbed_system ] + scrubbed_messages.map { |row| row[:content] }).join("\n").truncate(4000)

      unless settings.ai_enabled?
        call = log(purpose: purpose, version: version, status: "off",
          request: request_preview, conversation: conversation)
        return Result.new(text: "", status: :off, ai_call: call)
      end
      if over_daily_cap?(settings)
        call = log(purpose: purpose, version: version, model: settings.ai_model,
          status: "over_cap", request: request_preview, conversation: conversation)
        return Result.new(text: "", status: :over_cap, ai_call: call)
      end
      unless RateLimit.check_and_hit(settings)
        call = log(purpose: purpose, version: version, model: settings.ai_model,
          status: "rate_limited", request: request_preview, conversation: conversation)
        return Result.new(text: "", status: :rate_limited, ai_call: call)
      end

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      begin
        adapter = build_adapter(settings)
        raw = adapter.chat(system: scrubbed_system, messages: scrubbed_messages,
          max_tokens: max_tokens, json_mode: json_mode)
        text = Scrub.scrub(raw[:text].to_s.strip)
        cost = estimate_cost(raw[:input_tokens].to_i, raw[:output_tokens].to_i)
        call = log(purpose: purpose, version: version, model: settings.ai_model,
          input_tokens: raw[:input_tokens].to_i, output_tokens: raw[:output_tokens].to_i,
          cost_micro_cents: cost, latency_ms: raw[:latency_ms] ||
            ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round,
          status: "ok", request: request_preview, response: text.truncate(4000),
          conversation: conversation)
        Result.new(text: text, status: :ok, ai_call: call)
      rescue StandardError => e
        Rails.logger.warn("[ai] #{purpose} failed: #{e.class}: #{e.message}")
        call = log(purpose: purpose, version: version, model: settings.ai_model,
          status: "error", request: request_preview,
          response: "error: #{e.class}", conversation: conversation)
        Result.new(text: "", status: :error, ai_call: call)
      end
    end

    def self.build_adapter(settings)
      base = settings.ai_base_url.presence || "https://api.openai.com/v1"
      OpenAiAdapter.new(base_url: base, model: settings.ai_model, api_key: settings.ai_api_key)
    end

    def self.estimate_cost(input_tokens, output_tokens)
      input_tokens * 150 + output_tokens * 600
    end

    def self.log(purpose:, version:, model: nil, input_tokens: nil, output_tokens: nil,
      cost_micro_cents: 0, latency_ms: nil, status:, request: nil, response: nil, conversation: nil)
      AiCall.create!(
        purpose: purpose.to_s, prompt_version: version.to_s, model: model.to_s.presence,
        input_tokens: input_tokens, output_tokens: output_tokens, cost_micro_cents: cost_micro_cents.to_i,
        latency_ms: latency_ms, status: status.to_s,
        request_redacted: request.to_s.presence, response_redacted: response.to_s.presence,
        conversation: conversation
      )
    end
  end
end
