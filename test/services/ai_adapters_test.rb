require "test_helper"

class AiAdaptersTest < ActiveSupport::TestCase
  def fake_ok(payload)
    response = Net::HTTPOK.new("1.1", 200, "OK")
    response.instance_variable_set(:@read, true)
    response.instance_variable_set(:@body, JSON.generate(payload))
    response
  end

  def with_http(response)
    fake = Object.new
    fake.define_singleton_method(:request) { |_req| response }
    Net::HTTP.stub(:start, ->(*_args, **_kwargs, &blk) { blk.call(fake) }) do
      yield
    end
  end

  test "openai-compatible adapter parses text and usage" do
    payload = { choices: [ { message: { content: "Namaste!" } } ],
                usage: { prompt_tokens: 10, completion_tokens: 4 } }
    with_http(fake_ok(payload)) do
      result = Ai::OpenAiAdapter.new(base_url: "https://api.example.com/v1",
        model: "mini", api_key: "k").chat(system: "sys", messages: [ { role: :user, content: "hi" } ])
      assert_equal "Namaste!", result[:text]
      assert_equal 10, result[:input_tokens]
      assert_equal 4, result[:output_tokens]
      assert result[:latency_ms].is_a?(Integer)
    end
  end

  test "openai-compatible adapter raises on provider error" do
    error = Net::HTTPBadRequest.new("1.1", 400, "Bad")
    error.instance_variable_set(:@read, true)
    error.instance_variable_set(:@body, "{}")
    with_http(error) do
      assert_raises(RuntimeError) do
        Ai::OpenAiAdapter.new(base_url: "https://api.example.com/v1",
          model: "mini", api_key: "k").chat(system: "s", messages: [])
      end
    end
  end

  test "anthropic adapter parses blocks and usage" do
    payload = { content: [ { text: "Hello," }, { text: " trekker!" } ],
                usage: { input_tokens: 7, output_tokens: 3 } }
    with_http(fake_ok(payload)) do
      result = Ai::AnthropicAdapter.new(base_url: "", model: "haiku", api_key: "k")
        .chat(system: "sys", messages: [ { role: :user, content: "hi" } ])
      assert_equal "Hello, trekker!", result[:text]
      assert_equal 7, result[:input_tokens]
      assert_equal 3, result[:output_tokens]
    end
  end

  test "prompt version is pinned and logged" do
    assert_equal "v1", Ai::Prompts.version
    system, user = Ai::Prompts.render(:summarize_thread, thread: "hello")
    assert system.include?("Sherpa Holidays")
    assert user.include?("hello")
  end

  test "triage parse rejects unknown categories and sources" do
    parsed = Ai::Triage.parse('{"category":"nope","reason":"hello world","suggested_source":"billboard"}')
    assert_equal "other", parsed[:category]
    assert_nil parsed[:source]
  end

  test "suggest parse rejects title-less JSON" do
    assert_nil Ai::Suggest.parse('{"due_in_days":3}')
    assert_equal "Call Maya", Ai::Suggest.parse('{"title":"Call Maya","due_in_days":99,"reason":"x"}')["title"]
  end
end
