# Authenticated Microsoft Graph calls for one access token. Maps HTTP
# failures onto the shared Mail errors; the fetcher decides retry policy.
module Mail
  class GraphClient
    BASE = "https://graph.microsoft.com/v1.0"

    # 401 from Graph. invalid_grant means the grant itself is dead (revoked
    # or expired refresh lineage); anything else is a stale token worth one
    # forced refresh + retry.
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

    def initialize(access_token:, transport: GraphTransport.new)
      @access_token = access_token.to_s
      @transport = transport
    end

    def get_json(url, params: nil, headers: {})
      response = @transport.get_json(absolute(url), token: @access_token, params: params, headers: headers)
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
      when 429, 500, 502, 503, 504
        raise ConnectionError, "Microsoft Graph returned #{response.status}"
      else
        raise ConnectionError, "Microsoft Graph returned #{response.status}"
      end
    end

    def get_bytes(url)
      response = @transport.get_bytes(absolute(url), token: @access_token)
      case response.status
      when 200
        response.body.to_s.b
      when 401
        raise UnauthorizedError, "Microsoft rejected the access token"
      when 404
        raise NotFoundError, "Not found: #{url}"
      when 429, 500, 502, 503, 504
        raise ConnectionError, "Microsoft Graph returned #{response.status}"
      else
        raise ConnectionError, "Microsoft Graph returned #{response.status}"
      end
    end

    private

    def absolute(url)
      url.to_s.start_with?("http") ? url.to_s : "#{BASE}#{url}"
    end
  end
end
