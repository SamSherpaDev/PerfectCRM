require "test_helper"

class AiRateLimitTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    unless SolidCache::Entry.table_exists?
      ActiveRecord::Migration.suppress_messages { load Rails.root.join("db/cache_schema.rb") }
    end
    @previous_cache = Rails.cache
    Rails.cache = SolidCache::Store.new(namespace: "ai-rate-test-#{SecureRandom.hex(8)}")
    @settings = Struct.new(:ai_rate_limit_per_minute).new(1)
  end

  teardown { Rails.cache = @previous_cache }

  test "production cache allows only one concurrent request per minute" do
    travel_to Time.current.beginning_of_minute do
      ready = Queue.new
      start = Queue.new
      workers = 4.times.map do
        Thread.new do
          ready << true
          start.pop
          Ai::RateLimit.check_and_hit(@settings)
        end
      end
      4.times { ready.pop }
      4.times { start << true }
      results = workers.map(&:value)
      assert_equal 1, results.count(true)
      assert_equal 3, results.count(false)
      assert_not Ai::RateLimit.check_and_hit(@settings)
    end
    travel_to 1.minute.from_now.beginning_of_minute do
      assert Ai::RateLimit.check_and_hit(@settings)
      assert_not Ai::RateLimit.check_and_hit(@settings)
    end
  end

  test "cache failure does not grant a provider call" do
    Rails.cache.stub(:increment, nil) do
      assert_not Ai::RateLimit.check_and_hit(@settings)
    end
  end
end
