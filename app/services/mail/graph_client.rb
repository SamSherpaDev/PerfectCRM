# Authenticated Microsoft Graph calls. Maps HTTP failures onto the shared
# Mail errors and owns the access-token lifecycle: tokens are minted on
# first use from the block given to the constructor, and a stale-token 401
# refreshes once and retries that one request. Retrying per request (not
# per caller) matters because a full history walk outlives an access token,
# and replaying the walk would double-count what it already yielded. A
# second 401 means the grant itself is gone, so callers see
# GrantRevokedError and can offer Reconnect mailbox.
module Mail
  class GraphClient
    BASE = "https://graph.microsoft.com/v1.0"

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

    # 404: the message vanished between listing and fetch (deleted or moved
    # by the captain mid-run). Callers skip it; it is not an error.
    class NotFoundError < GraphError; end
    # 410 Gone on a deltaLink: the sync token expired server-side.
    class GoneError < GraphError; end

    REVOKED = "Mailbox access was revoked or expired. Reconnect the mailbox in Settings.".freeze

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
        else
          raise ConnectionError, "Microsoft Graph returned #{response.status}"
        end
      end
    end

    private

    def with_token
      attempts = 0
      begin
        attempts += 1
        yield access_token
      rescue UnauthorizedError => e
        raise GrantRevokedError, REVOKED if e.invalid_grant? || attempts > 1

        @access_token = nil
        retry
      end
    end

    def access_token
      @access_token ||= @token_source.call.to_s
    end

    def absolute(url)
      url.to_s.start_with?("http") ? url.to_s : "#{BASE}#{url}"
    end
  end
end
