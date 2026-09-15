# frozen_string_literal: true

require "net/http"
require "json"

# OpenAI-compatible chat adapter: works for OpenAI and OpenRouter through
# the base URL, model, and key the captain stores in Settings.
module Ai
  class OpenAiAdapter
    def initialize(base_url:, model:, api_key:)
      @base_url = base_url.to_s.sub(%r{/+\z}, "")
      @model = model.to_s
      @api_key = api_key.to_s
    end

    def chat(system:, messages:, max_tokens: 800, json_mode: false)
      uri = URI("#{@base_url}/chat/completions")
      payload = {
        model: @model,
        max_tokens: max_tokens,
        messages: [ { role: "system", content: system }, *messages ]
      }
      payload[:response_format] = { type: "json_object" } if json_mode
      request = Net::HTTP::Post.new(uri)
      request["Authorization"] = "Bearer #{@api_key}"
      request["Content-Type"] = "application/json"
      request.body = JSON.generate(payload)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https",
        open_timeout: 10, read_timeout: 60) { |http| http.request(request) }
      latency_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
      raise "AI provider error #{response.code}" unless response.is_a?(Net::HTTPSuccess)

      body = JSON.parse(response.body)
      choice = body.dig("choices", 0, "message", "content").to_s
      usage = body["usage"] || {}
      { text: choice, input_tokens: usage["prompt_tokens"].to_i,
        output_tokens: usage["completion_tokens"].to_i, latency_ms: latency_ms }
    end
  end
end
