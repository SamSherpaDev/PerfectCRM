require "test_helper"

class LeadsTest < ActiveSupport::TestCase
  test "only kid supplies the relay caller name" do
    secret = "test-secret"
    signature = Leads.sign_relay_body("{}", secret)
    assert_equal "relay", Leads.verify_relay_signature("{}", "#{signature},k=panda", secret: secret)
    assert_equal "panda", Leads.verify_relay_signature("{}", "#{signature},kid=panda", secret: secret)
    assert_nil Leads.verify_relay_signature("{}", "#{signature},invalid", secret: secret)
  end

  test "suspicion_hits scores fast and missing timing as high-confidence and single moderate hits as low-confidence" do
    score, hits = Leads.suspicion_hits(name: "Anna Lindqvist", email: "anna@example.com", message: "Spring trek", seconds_to_submit: 12.4)
    assert_equal [ 0, [] ], [ score, hits ]
    assert_not Leads.high_confidence_spam?(score)

    score, hits = Leads.suspicion_hits(name: "Anna Lindqvist", email: "annalindqvist@example.com", message: "Spring trek", seconds_to_submit: 12.4)
    assert_equal [ 25, [ :name_matches_email ] ], [ score, hits ]
    assert_not Leads.high_confidence_spam?(score)
    assert_equal "Name matches email", Leads.spam_reason(hits)

    score, hits = Leads.suspicion_hits(name: "Anna Lindqvist", email: "anna@example.com", message: "Spring trek", seconds_to_submit: 1.5)
    assert_equal [ 50, [ :too_fast ] ], [ score, hits ]
    assert Leads.high_confidence_spam?(score)
    assert_equal "Submitted under 3s", Leads.spam_reason(hits)

    score, hits = Leads.suspicion_hits(name: "Anna Lindqvist", email: "anna@example.com", message: "Spring trek", seconds_to_submit: nil)
    assert_equal [ 50, [ :missing_timing ] ], [ score, hits ]
    assert Leads.high_confidence_spam?(score)
    assert_equal "Missing or invalid timing", Leads.spam_reason(hits)
  end

  test "near_identical_message detects exact, punctuation-varied, and minor-edit duplicates while keeping distinct messages separate" do
    assert Leads.near_identical_message?(
      "Two of us, first time in Nepal, thinking spring.",
      "two of us first time in nepal thinking spring!"
    )
    assert Leads.near_identical_message?(
      "Two of us, first time in Nepal, thinking spring.",
      "Two of us, first time in Nepal, thinking spring 2027."
    )
    assert_not Leads.near_identical_message?(
      "Two of us, first time in Nepal, thinking spring.",
      "Looking for an autumn Bhutan trip for four travelers."
    )
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
