require "test_helper"

class LeadsTest < ActiveSupport::TestCase
  test "only kid supplies the relay caller name" do
    secret = "test-secret"
    signature = Leads.sign_relay_body("{}", secret)
    assert_equal "relay", Leads.verify_relay_signature("{}", "#{signature},k=panda", secret: secret)
    assert_equal "panda", Leads.verify_relay_signature("{}", "#{signature},kid=panda", secret: secret)
    assert_nil Leads.verify_relay_signature("{}", "#{signature},invalid", secret: secret)
  end
end

class LeadsRateLimitTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    LeadRateLimitEntry.delete_all
  end

  teardown do
    LeadRateLimitEntry.delete_all
  end

  test "concurrent admissions cannot exceed the window limit" do
    now = Time.current
    9.times { assert_nil Leads.rate_limit_exceeded?("concurrent", limit: 10, window: 600, now: now) }
    ready = Queue.new
    start = Queue.new
    workers = 2.times.map do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          ready << true
          start.pop
          Leads.rate_limit_exceeded?("concurrent", limit: 10, window: 600, now: now)
        end
      end
    end
    2.times { ready.pop }
    2.times { start << true }
    results = workers.map(&:value)
    assert_equal 1, results.count(nil)
    assert_equal 1, results.count { |result| result.is_a?(Integer) && result.positive? }
    assert_equal 10, LeadRateLimitEntry.where(key: "concurrent").count
    assert_nil Leads.rate_limit_exceeded?("concurrent", limit: 10, window: 600, now: now + 601)
    assert_equal 1, LeadRateLimitEntry.where(key: "concurrent").count
  end
end
