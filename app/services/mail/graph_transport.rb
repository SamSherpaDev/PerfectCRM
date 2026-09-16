require "net/http"
require "uri"
require "json"

# Raw HTTP transport for Microsoft identity + Graph calls. Kept separate so
# tests can inject a stub transport; production goes through Net::HTTP with
# short timeouts, mirroring PerfectBook::Client.
module Mail
  class GraphTransport
    OPEN_TIMEOUT = 5
    READ_TIMEOUT = 20

    Response = Struct.new(:status, :body, keyword_init: true) do
      def json
        JSON.parse(body.to_s)
      rescue JSON::ParserError
        {}
      end
    end

    def post_form(url, params)
      uri = URI.parse(url.to_s)
      http = build_http(uri)
      request = Net::HTTP::Post.new(uri.request_uri)
      request.set_form_data(params)
      request["Accept"] = "application/json"
      Response.new(status: nil, body: nil).tap do |response|
        http_response = http.request(request)
        response.status = http_response.code.to_i
        response.body = http_response.body.to_s
      end
    rescue Net::OpenTimeout, Net::ReadTimeout, SocketError, SystemCallError, IOError, OpenSSL::SSL::SSLError => e
      raise ConnectionError, "Microsoft identity endpoint unreachable (#{e.class})"
    end

    def get_json(url, token:, params: nil, headers: {})
      get(url, token: token, params: params, headers: headers) do |http_response|
        Response.new(status: http_response.code.to_i, body: http_response.body.to_s)
      end
    end

    def get_bytes(url, token:)
      get(url, token: token) do |http_response|
        Response.new(status: http_response.code.to_i, body: http_response.body.to_s.b)
      end
    end

    private

    def get(url, token:, params: nil, headers: {})
      uri = URI.parse(url.to_s)
      if params&.any?
        query = URI.encode_www_form(params)
        uri.query = [ uri.query, query ].compact.join("&")
      end
      http = build_http(uri)
      request = Net::HTTP::Get.new(uri.request_uri)
      request["Accept"] = "application/json"
      request["Authorization"] = "Bearer #{token}"
      headers.each { |key, value| request[key] = value }
      yield http.request(request)
    rescue Net::OpenTimeout, Net::ReadTimeout, SocketError, SystemCallError, IOError, OpenSSL::SSL::SSLError => e
      raise ConnectionError, "Microsoft Graph unreachable (#{e.class})"
    end

    def build_http(uri)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = OPEN_TIMEOUT
      http.read_timeout = READ_TIMEOUT
      http
    end
  end
end
