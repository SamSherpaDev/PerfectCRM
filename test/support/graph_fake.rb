# Stub Microsoft Graph + identity HTTP for mail tests. FakeMailbox scripts a
# two-folder mailbox (inbox + sentitems) with delta sync, history listing,
# message GETs, attachment bytes, and token responses; tests drive it instead
# of the network. Nothing here touches real Microsoft endpoints.
require "json"
require "uri"

class FakeGraphTransport < Mail::GraphTransport
  Request = Struct.new(:method, :url, :params, :headers, keyword_init: true)

  def initialize
    @get_handlers = []
    @post_handlers = []
    @requests = []
  end

  attr_reader :requests

  def on_get(match = nil, &block)
    @get_handlers << [ match, block ]
  end

  def on_post(match = nil, &block)
    @post_handlers << [ match, block ]
  end

  def post_form(url, params)
    @requests << Request.new(method: :post, url: url.to_s, params: params, headers: {})
    handler = @post_handlers.reverse.find { |match, _| matches?(match, url) }
    raise "unstubbed POST #{url}" if handler.nil?

    build_response(handler[1].call(url.to_s, params))
  end

  def get_json(url, token:, params: nil, headers: {})
    @requests << Request.new(method: :get, url: url.to_s, params: params, headers: headers)
    handler = @get_handlers.reverse.find { |match, _| matches?(match, url) }
    raise "unstubbed GET #{url}" if handler.nil?

    build_response(handler[1].call(url.to_s, token: token, params: params, headers: headers))
  end

  def get_bytes(url, token:)
    @requests << Request.new(method: :get_bytes, url: url.to_s, params: nil, headers: {})
    handler = @get_handlers.reverse.find { |match, _| matches?(match, url) }
    raise "unstubbed GET(bytes) #{url}" if handler.nil?

    build_response(handler[1].call(url.to_s, token: token, params: nil, headers: {}))
  end

  private

  def matches?(match, url)
    match.nil? ||
      (match.is_a?(Regexp) ? url.to_s.match?(match) : url.to_s.include?(match.to_s))
  end

  def build_response(result)
    return result if result.is_a?(Mail::GraphTransport::Response)

    if result.key?(:bytes)
      Mail::GraphTransport::Response.new(status: result[:status] || 200, body: result[:bytes])
    else
      Mail::GraphTransport::Response.new(status: result[:status] || 200, body: JSON.generate(result.fetch(:json, {})))
    end
  end
end

# Builds Graph-shaped message hashes for tests.
module GraphMessageBuilder
  def graph_address(email)
    { "emailAddress" => { "address" => email, "name" => email } }
  end

  def graph_message(id:, from:, to: [ "info@sherpaholidays.com" ], cc: [], bcc: [],
      subject: "Hello", message_id: nil, conversation: "conv-1", categories: [],
      received: "2026-09-15T10:00:00Z", sent: nil, headers: [], attachments: [],
      body: "Hi there", body_type: "text", preview: nil)
    {
      "id" => id,
      "internetMessageId" => message_id,
      "conversationId" => conversation,
      "categories" => categories,
      "from" => graph_address(from),
      "toRecipients" => Array(to).map { |email| graph_address(email) },
      "ccRecipients" => Array(cc).map { |email| graph_address(email) },
      "bccRecipients" => Array(bcc).map { |email| graph_address(email) },
      "subject" => subject,
      "body" => { "contentType" => body_type, "content" => body },
      "bodyPreview" => preview || body.to_s[0, 140],
      "receivedDateTime" => received,
      "sentDateTime" => sent || received,
      "hasAttachments" => attachments.any?,
      "isRead" => false,
      "internetMessageHeaders" => headers,
      "attachments" => attachments
    }
  end

  def graph_file_attachment(id:, name:, content_type: "text/plain", size: 11)
    { "@odata.type" => "#microsoft.graph.fileAttachment", "id" => id,
      "name" => name, "contentType" => content_type, "size" => size, "isInline" => false }
  end

  def graph_item_attachment(id:, name: "forwarded")
    { "@odata.type" => "#microsoft.graph.itemAttachment", "id" => id,
      "name" => name, "contentType" => "message/rfc822", "size" => 1000, "isInline" => false }
  end
end

# Scripted two-folder mailbox behind a FakeGraphTransport.
class FakeMailbox
  include GraphMessageBuilder

  HISTORY_PAGE_SIZE = 2

  def initialize
    @transport = FakeGraphTransport.new
    @messages = Hash.new { |hash, key| hash[key] = [] }
    # Issued sync links map to the mailbox position they represent, so
    # re-requesting an uncommitted link replays (like real delta tokens).
    @link_ack = {}
    @token_gen = 0
    @attachment_bytes = {}
    @nested_items = {}
    @token_calls = 0
    @grant_mode = :ok
    @expired_deltas = Hash.new(false)
    install_handlers
  end

  attr_reader :transport, :token_calls

  def requests
    @transport.requests
  end

  # Adds a message to a folder. file_bytes maps attachment id -> raw bytes;
  # nested maps item-attachment id -> the forwarded item hash.
  def add(folder, message, file_bytes: {}, nested: {})
    @messages[folder] << message
    file_bytes.each { |(key, bytes)| @attachment_bytes[[ message["id"], key ]] = bytes }
    nested.each { |(key, item)| @nested_items[[ message["id"], key ]] = item }
    message
  end

  def find(id)
    @messages.values.flatten.find { |message| message["id"] == id }
  end

  # Next token POST answers invalid_grant (revoked/expired grant).
  def refuse_grant!
    @grant_mode = :revoked
  end

  # The next delta call for the folder answers 410 Gone (expired sync token).
  def expire_delta!(folder)
    @expired_deltas[folder] = true
  end

  def token_posts
    requests.count { |request| request.method == :post }
  end

  def byte_fetches
    requests.count { |request| request.method == :get_bytes }
  end

  private

  def install_handlers
    @transport.on_post("oauth2/v2.0/token") do |_url, params|
      @token_calls += 1
      if @grant_mode == :revoked
        { status: 400, json: { "error" => "invalid_grant", "error_description" => "grant revoked" } }
      else
        { status: 200, json: { "access_token" => "access-#{@token_calls}",
          "refresh_token" => "refresh-#{@token_calls + 1}", "expires_in" => 3600 } }
      end
    end

    # Registered general-first: matching prefers the last registration, so
    # the bare /me check must not shadow message/folder URLs.
    @transport.on_get("/me") do |_url, token:, params:, headers:|
      { status: 200, json: { "id" => "captain", "mail" => "info@sherpaholidays.com",
        "userPrincipalName" => "info@sherpaholidays.com" } }
    end

    @transport.on_get("mailFolders/") do |url, token:, params:, headers:|
      route_folder_get(url, headers)
    end

    @transport.on_get("/me/messages/") do |url, token:, params:, headers:|
      route_message_get(url, params)
    end
  end

  def route_message_get(url, params)
    if url.include?("/attachments/") && url.include?("$value")
      parts = url.split("/me/messages/").last.split("/")
      bytes = @attachment_bytes[[ parts[0], parts[2] ]]
      return bytes.nil? ? { status: 404, json: {} } : { status: 200, bytes: bytes }
    end
    if url.include?("/attachments/")
      message_id, _, attachment_id = url.split("/me/messages/").last.split("/")
      item = @nested_items[[ message_id, attachment_id.split("?").first ]]
      return item.nil? ? { status: 404, json: {} } : { status: 200, json: { "item" => item } }
    end
    id = url.split("/me/messages/").last.split("?").first
    message = find(id)
    message.nil? ? { status: 404, json: {} } : { status: 200, json: message }
  end

  def route_folder_get(url, headers)
    folder = url[%r{mailFolders/([^/]+)}, 1]
    if url.include?("/messages/delta")
      delta_get(folder, url)
    else
      history_get(folder, url)
    end
  end

  def delta_get(folder, url)
    if url.include?("$deltatoken=")
      if @expired_deltas[folder]
        @expired_deltas[folder] = false
        return { status: 410, json: {} }
      end
      from = @link_ack[[ folder, url[/\$deltatoken=(\d+)/, 1].to_i ]] || 0
      fresh = @messages[folder][from..] || []
      { status: 200, json: { "value" => fresh, "@odata.deltaLink" => issue_delta_link(folder) } }
    elsif url.include?("$skiptoken=")
      from = @link_ack[[ folder, url[/\$skiptoken=(\d+)/, 1].to_i ]] || 0
      rest = @messages[folder][from..] || []
      { status: 200, json: { "value" => rest, "@odata.deltaLink" => issue_delta_link(folder) } }
    else
      first = @messages[folder][0..0] || []
      if @messages[folder].length > 1
        { status: 200, json: { "value" => first, "@odata.nextLink" => issue_skip_link(folder, 1) } }
      else
        { status: 200, json: { "value" => first, "@odata.deltaLink" => issue_delta_link(folder) } }
      end
    end
  end

  def history_get(folder, url)
    query = URI.decode_www_form(URI.parse(url).query.to_s).to_h
    items = @messages[folder].sort_by { |message| [ message["receivedDateTime"].to_s, message["id"].to_s ] }
    if query["$filter"].to_s.include?("receivedDateTime ge")
      floor = query["$filter"][/receivedDateTime ge (\S+)/, 1].to_s
      items = items.select { |message| message["receivedDateTime"].to_s >= floor }
    end
    skip = query["$skip"].to_i
    page = items[skip, HISTORY_PAGE_SIZE] || []
    value = page.map { |message| { "id" => message["id"], "receivedDateTime" => message["receivedDateTime"] } }
    payload = { "value" => value }
    if skip + HISTORY_PAGE_SIZE < items.length
      base = url.split("?").first
      rest = URI.decode_www_form(URI.parse(url).query.to_s).to_h.merge("$skip" => (skip + HISTORY_PAGE_SIZE).to_s)
      payload["@odata.nextLink"] = "#{base}?#{URI.encode_www_form(rest)}"
    end
    { status: 200, json: payload }
  end

  def issue_delta_link(folder)
    @token_gen += 1
    @link_ack[[ folder, @token_gen ]] = @messages[folder].length
    "https://graph.microsoft.com/v1.0/me/mailFolders/#{folder}/messages/delta?$deltatoken=#{@token_gen}"
  end

  def issue_skip_link(folder, from)
    @token_gen += 1
    @link_ack[[ folder, @token_gen ]] = from
    "https://graph.microsoft.com/v1.0/me/mailFolders/#{folder}/messages/delta?$skiptoken=#{@token_gen}"
  end
end
