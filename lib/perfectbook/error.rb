# Error hierarchy for the PerfectBook read API. Never includes the token.
module PerfectBook
  class Error < StandardError; end

  # Local token missing, or PerfectBook itself has no token configured
  # (the whole API answers 404 when unconfigured).
  class NotConfiguredError < Error; end

  class UnauthorizedError < Error; end
  class NotFoundError < Error; end
  class BadRequestError < Error; end

  # 429 with a Retry-After hint in seconds (nil when absent).
  class RateLimitedError < Error
    attr_reader :retry_after

    def initialize(message = "Rate limited", retry_after: nil)
      @retry_after = retry_after
      super(message)
    end
  end

  # 5xx, timeouts, and connection failures.
  class UnavailableError < Error; end

  # Raised without an HTTP call while the circuit is open.
  class CircuitOpenError < UnavailableError; end
end
