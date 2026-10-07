require "test_helper"

class AiRateLimitTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  self.use_transactional_tests = false

  setup do
    @previous_cache = Rails.cache
    # Expiry stays on the test job adapter instead of outliving this test in a thread.
    Rails.cache = SolidCache::Store.new(namespace: "ai-rate-test-#{SecureRandom.hex(8)}", expiry_method: :job)
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
          SolidCache::Entry.connection_pool.with_connection do
            Ai::RateLimit.check_and_hit(@settings)
          end
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

  test "cache write transactions cannot lock primary records" do
    ready = Queue.new
    release = Queue.new
    writer = Thread.new do
      begin
        SolidCache::Entry.transaction do
          raise "cache write failed" unless Rails.cache.write("held-write", true)
          ready << nil
          release.pop
        end
      rescue => error
        ready << error
        raise
      end
    end

    error = ready.pop
    raise error if error

    Setting.transaction do
      Setting.current.update!(appearance: "night")
      assert_equal "night", Setting.current.appearance
      raise ActiveRecord::Rollback
    end
  ensure
    release << true
    writer&.value
  end

  test "cache failure does not grant a provider call" do
    Rails.cache.stub(:increment, nil) do
      assert_not Ai::RateLimit.check_and_hit(@settings)
    end
  end
end
