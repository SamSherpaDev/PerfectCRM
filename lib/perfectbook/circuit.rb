# Circuit breaker so a failing PerfectBook does not get hammered.
# After repeated failures the client raises CircuitOpenError without an
# HTTP call until the cooldown (one poll interval) passes.
module PerfectBook
  module Circuit
    THRESHOLD = 5
    COOLDOWN = 15.minutes

    CACHE_FAILURES_KEY = "perfectbook:circuit:failures"
    CACHE_OPENED_KEY = "perfectbook:circuit:opened_at"

    # Dedicated memory store: the test cache is :null_store and cannot
    # count, and per-process limiting is plenty for one internal client.
    STORE = ActiveSupport::Cache::MemoryStore.new

    class << self
      def allow_request?
        !open?
      end

      def open?
        failures = store.read(CACHE_FAILURES_KEY).to_i
        return false if failures < THRESHOLD

        opened_at = parse_time(store.read(CACHE_OPENED_KEY))
        return true if opened_at.nil?
        return false if Time.current - opened_at >= COOLDOWN

        true
      end

      def record_success
        store.delete(CACHE_FAILURES_KEY)
        store.delete(CACHE_OPENED_KEY)
      end

      def record_failure
        failures = store.read(CACHE_FAILURES_KEY).to_i + 1
        store.write(CACHE_FAILURES_KEY, failures, expires_in: COOLDOWN * 2)
        store.write(CACHE_OPENED_KEY, Time.current.iso8601, expires_in: COOLDOWN * 2) if failures >= THRESHOLD
        failures
      end

      def reset!
        store.delete(CACHE_FAILURES_KEY)
        store.delete(CACHE_OPENED_KEY)
      end

      private

      def store
        STORE
      end

      def parse_time(value)
        return nil if value.blank?

        Time.iso8601(value.to_s)
      rescue ArgumentError
        nil
      end
    end
  end
end
