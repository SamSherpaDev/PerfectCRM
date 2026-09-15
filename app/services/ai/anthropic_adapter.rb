# frozen_string_literal: true

require "net/http"
require "json"

# Anthropic messages adapter behind the same chat interface.
module Ai
  class AnthropicAdapter
    DEFAULT_BASE = "https://api.anthropic.com".freeze

    def initialize(base_url:, model:, api_key:)
      @base_url = base_url.presence.to_s.sub(%r{/+\z}, "").presence || DEFAULT_BASE
      @model = model.to_s
      @api_key = api_key.to_s
    end

    def chat(system:, messages:, max_tokens: 800, json_mode: false)
      uri = URI("#{@base_url}/v1/messages")
      prompt = system.to_s
      prompt += "\n\nReply with JSON only." if json_mode
      payload = {
        model: @model,
        max_tokens: max_tokens,
        system: prompt,
        messages: messages.map { |row| { role: row[:role] == :assistant ? "assistant" : "user", content: row[:content].to_s } }
      }
      request = Net::HTTP::Post.new(uri)
      request["x-api-key"] = @api_key
      request["anthropic-version"] = "2023-06-01"
      request["Content-Type"] = "application/json"
      request.body = JSON.generate(payload)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https",
        open_timeout: 10, read_timeout: 60) { |http| http.request(request) }
      latency_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
      raise "AI provider error #{response.code}" unless response.is_a?(Net::HTTPSuccess)

      body = JSON.parse(response.body)
      text = Array(body["content"]).map { |block| block["text"].to_s }.join
      usage = body["usage"] || {}
      { text: text, input_tokens: usage["input_tokens"].to_i,
        output_tokens: usage["output_tokens"].to_i, latency_ms: latency_ms }
    end
  end
end
