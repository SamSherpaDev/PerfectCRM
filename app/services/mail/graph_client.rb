# Authenticated Microsoft Graph calls. Maps HTTP failures onto the shared
# Mail errors and owns the access-token lifecycle: tokens are minted on
# first use from the block given to the constructor, and a stale-token 401
# refreshes once and retries that one request. Retrying per request (not
# per caller) matters because a full history walk outlives an access token,
# and replaying the walk would double-count what it already yielded. A
# second 401 means the grant itself is gone, so callers see
# GrantRevokedError and can offer Reconnect mailbox.
#
# Throttling (429) is a wait, not a failure: Outlook throttles reads per app
# per mailbox and a history backfill is long enough to meet it routinely, so
# the Retry-After Graph sends is honoured for a bounded number of waits
# before the run gives up. Without that a throttle would surface to the
# captain as a failed import he has to restart by hand.
module Mail
  class GraphClient
    BASE = "https://graph.microsoft.com/v1.0"

    # How many throttled waits one request rides out, how long a single wait
    # may last whatever Retry-After asks for, and what to wait when Graph
    # sends no Retry-After at all.
    THROTTLE_WAITS = 3
    MAX_WAIT_SECONDS = 60
    DEFAULT_WAIT_SECONDS = 5

    # 401 from Graph, handled entirely inside this class: invalid_grant
    # means the grant is dead, anything else is worth one forced refresh.
    class UnauthorizedError < GraphError
      def initialize(message = "Microsoft rejected the access token", invalid_grant: false)
        @invalid_grant = invalid_grant
        super(message)
      end

      def invalid_grant?
        !!@invalid_grant
      end
    end

    # 429, handled entirely inside this class: waited out, never raised to
    # callers as-is.
    class ThrottledError < GraphError
      attr_reader :retry_after

      def initialize(message = "Microsoft Graph is throttling this mailbox", retry_after: nil)
        @retry_after = retry_after
        super(message)
      end
    end

    # 404: the message vanished between listing and fetch (deleted or moved
    # by the captain mid-run). Callers skip it; it is not an error.
    class NotFoundError < GraphError; end
    # 410 Gone on a deltaLink: the sync token expired server-side.
    class GoneError < GraphError; end

    REVOKED = "Mailbox access was revoked or expired. Reconnect the mailbox in Settings.".freeze
    THROTTLED = "Microsoft Graph is throttling this mailbox. Try again shortly.".freeze

    def initialize(transport: GraphTransport.new, &token_source)
      @transport = transport
      @token_source = token_source
    end

    def get_json(url, params: nil, headers: {})
      with_token do |token|
        response = @transport.get_json(absolute(url), token: token, params: params, headers: headers)
        case response.status
        when 200
          response.json
        when 401
          raise UnauthorizedError.new("Microsoft rejected the access token",
            invalid_grant: response.json["error"].is_a?(Hash) && response.json["error"]["code"].to_s == "InvalidGrant")
        when 404
          raise NotFoundError, "Not found: #{url}"
        when 410
          raise GoneError, "The sync token expired"
        when 429
          raise ThrottledError.new(retry_after: response.retry_after)
        else
          raise ConnectionError, "Microsoft Graph returned #{response.status}"
        end
      end
    end

    def get_bytes(url)
      with_token do |token|
        response = @transport.get_bytes(absolute(url), token: token)
        case response.status
        when 200
          response.body.to_s.b
        when 401
          raise UnauthorizedError, "Microsoft rejected the access token"
        when 404
          raise NotFoundError, "Not found: #{url}"
        when 429
          raise ThrottledError.new(retry_after: response.retry_after)
        else
          raise ConnectionError, "Microsoft Graph returned #{response.status}"
        end
      end
    end

    private

    def with_token
      refreshed = false
      waits = 0
      begin
        yield access_token
      rescue UnauthorizedError => e
        raise GrantRevokedError, REVOKED if e.invalid_grant? || refreshed

        refreshed = true
        @access_token = nil
        retry
      rescue ThrottledError => e
        raise ConnectionError, THROTTLED if waits >= THROTTLE_WAITS

        waits += 1
        sleep wait_seconds(e.retry_after)
        retry
      end
    end

    # Graph sends Retry-After in seconds, but RFC 7231 also permits an
    # HTTP-date and a gateway in front of Graph may use it. Anything that
    # parses is capped, so one throttled request can never park a job for
    # minutes; anything that does not falls back to the default wait, never
    # to zero, which would burn every retry in milliseconds and press
    # harder on the throttle being ridden out.
    def wait_seconds(retry_after)
      value = retry_after.to_s.strip
      return DEFAULT_WAIT_SECONDS if value.empty?
      return value.to_i.clamp(0, MAX_WAIT_SECONDS) if value.match?(/\A\d+\z/)

      seconds = (Time.httpdate(value) - Time.now).ceil
      # A date already in the past says nothing useful - gateway clock skew
      # is ordinary - and retrying instantly would burn every wait in
      # milliseconds, so it is treated as absent rather than as permission.
      return DEFAULT_WAIT_SECONDS if seconds <= 0

      seconds.clamp(1, MAX_WAIT_SECONDS)
    rescue ArgumentError
      DEFAULT_WAIT_SECONDS
    end

    def access_token
      @access_token ||= @token_source.call.to_s
    end

    def absolute(url)
      url.to_s.start_with?("http") ? url.to_s : "#{BASE}#{url}"
    end
  end
end
