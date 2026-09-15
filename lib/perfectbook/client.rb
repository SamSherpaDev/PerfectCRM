require "net/http"
require "uri"
require "json"

# Client for PerfectBook's sibling API: mirror reads and document hand-off
# (PerfectBook README, "API for sibling apps").
#
# Contract notes the client depends on:
# - Bearer token in Authorization; whole API 404s when PerfectBook has no
#   token configured; 120 requests/minute per token (429 + Retry-After).
# - Collection reads use ETags; If-None-Match gives 304.
# - Cursor pagination (limit up to 100, pagination.next_cursor/has_more).
# - updated_since only on /contacts; money as integer minor units plus
#   currency; price_per_person_minor always null on departures today;
#   phone always null on contacts; v1 additive-only versioning.
#
# The token never appears in logs (see filtered params + careful logging).
module PerfectBook
  class Client
    OPEN_TIMEOUT = 5
    READ_TIMEOUT = 10
    MAX_LIMIT = 100

    Contact = Struct.new(:id, :kind, :name, :email, :phone, :country, :state,
      :archived, :created_at, :updated_at, keyword_init: true)
    Trip = Struct.new(:id, :name, :active, :status, :shopify_product_id,
      :departures_count, :departure_ids, :first_start_date, :last_end_date,
      :created_at, :updated_at, keyword_init: true)
    Departure = Struct.new(:id, :trip_id, :trip_name, :label, :start_date,
      :end_date, :duration_days, :place, :country_codes, :status, :seats,
      :booked_seats, :available_seats, :price_per_person_minor, :currency,
      :created_at, :updated_at, keyword_init: true)
    Booking = Struct.new(:id, :ref, :status, :trip_id, :trip_name,
      :departure_id, :departure_place, :start_date, :end_date, :party_size,
      :price_per_person_minor, :total_minor, :paid_minor, :balance_due_minor,
      :currency, :invoice_badge, :invoice_number, :payment_reference,
      :deep_link, :documents, :checklist, :missing_count, keyword_init: true)

    # Upload handoff result: traveler + document outcome, booking
    # missing_count, and whether PerfectBook replayed an earlier upload_id.
    UploadResult = Struct.new(:traveler_id, :traveler_name, :document_type,
      :document_status, :received_at, :missing_count, :duplicate, keyword_init: true)

    # Collection fetch result: data plus whether the server answered 304.
    Page = Struct.new(:data, :pagination, :not_modified, :etag, keyword_init: true)

    def initialize(base_url: PerfectBook.base_url, api_token: PerfectBook.api_token, etag_store: nil, pace_requests: false)
      @base_url = base_url.to_s.sub(%r{/+\z}, "")
      @api_token = api_token.to_s
      @etag_store = etag_store || EtagStore
      @pace_requests = pace_requests
    end

    # Used by the Settings "Test connection" button: a cheap one-row read.
    def test_connection
      page = get_collection("/api/v1/contacts", limit: 1)
      true
    end

    def list_contacts(updated_since: nil, kind: nil, limit: MAX_LIMIT)
      params = { limit: limit }
      params[:updated_since] = updated_since.iso8601 if updated_since.respond_to?(:iso8601)
      params[:updated_since] = updated_since.to_s if updated_since.is_a?(String) && updated_since.present?
      params[:kind] = kind if kind.present?
      walk_collection("/api/v1/contacts", params) { |row| build_contact(row) }
    end

    def fetch_contact(id)
      json = get_single("/api/v1/contacts/#{id}")
      return { data: nil, not_modified: true } if json[:not_modified]

      { data: build_contact(json[:data]), not_modified: false }
    end

    def list_contact_bookings(contact_id, limit: MAX_LIMIT)
      walk_collection("/api/v1/contacts/#{contact_id}/bookings", { limit: limit }) { |row| build_booking(row) }
    end

    def list_trips(limit: MAX_LIMIT)
      walk_collection("/api/v1/trips", { limit: limit }) { |row| build_trip(row) }
    end

    def list_departures(trip_id: nil, limit: MAX_LIMIT)
      params = { limit: limit }
      params[:trip_id] = trip_id if trip_id.present?
      walk_collection("/api/v1/departures", params) { |row| build_departure(row) }
    end

    # Document upload handoff (the API's only write): stores a traveler
    # file in PerfectBook's encrypted record. upload_id must be stable
    # per CRM attachment (the holding or attachment id) so retries replay
    # instead of duplicating. Returns an UploadResult.
    def upload_traveler_document(booking_ref:, traveler_id:, file:, filename:, content_type:, document_type:, upload_id:)
      raise NotConfiguredError, "PerfectBook API token is not configured" if @api_token.blank?
      raise CircuitOpenError, "PerfectBook circuit is open; skipping request" unless Circuit.allow_request?

      started = Time.current
      http_response = perform_upload(booking_ref, traveler_id,
        file: file, filename: filename, content_type: content_type,
        document_type: document_type, upload_id: upload_id)
      elapsed = ((Time.current - started) * 1000).round
      Rails.logger.info("PerfectBook POST bookings/#{booking_ref}/travelers/#{traveler_id}/documents -> #{http_response.code} (#{elapsed}ms)")

      case http_response.code.to_i
      when 200, 201
        Circuit.record_success
        build_upload_result(JSON.parse(http_response.body.to_s))
      when 400
        raise BadRequestError, safe_message(http_response)
      when 401
        raise UnauthorizedError, "PerfectBook rejected the API token"
      when 404
        raise NotFoundError, safe_message(http_response)
      when 422
        raise UnprocessableError, safe_message(http_response)
      when 429
        raise RateLimitedError.new("PerfectBook rate limit reached", retry_after: retry_after(http_response))
      when 500..599
        Circuit.record_failure
        raise UnavailableError, "PerfectBook is unavailable (#{http_response.code})"
      else
        raise Error, safe_message(http_response)
      end
    rescue Net::OpenTimeout, Net::ReadTimeout => e
      Circuit.record_failure
      raise UnavailableError, "PerfectBook timed out (#{e.class})"
    rescue SocketError, SystemCallError, IOError, OpenSSL::SSL::SSLError => e
      Circuit.record_failure
      raise UnavailableError, "PerfectBook connection failed (#{e.class})"
    rescue JSON::ParserError
      raise Error, "PerfectBook returned invalid JSON"
    end

    private

    # not_modified is true only when the first page answered 304.
    # Otherwise the consumer must call commit_etags only after applying
    # the entire collection successfully, so failed syncs remain fetchable.
    def walk_collection(path, params)
      all = []
      cursor = nil
      validators = {}
      first_page = true
      loop do
        page_params = params.merge(cursor: cursor).compact
        page = get_collection(path, **page_params)
        if page.not_modified
          return { data: [], not_modified: true } if first_page

          page = get_collection(path, conditional: false, **page_params)
          raise Error, "PerfectBook returned 304 without a cached body" if page.not_modified
        end
        validators[page.etag.first] = page.etag.last if page.etag
        first_page = false
        all.concat(page.data.map { |row| yield row })
        break unless page.pagination["has_more"]

        cursor = page.pagination["next_cursor"]
        break if cursor.blank?
      end
      { data: all, not_modified: false, commit_etags: -> { validators.each { |key, etag| @etag_store.write(key, etag) } } }
    end

    def get_collection(path, conditional: true, **params)
      query = params.compact
      response = get(path, query, collection: true, conditional: conditional)
      return Page.new(data: [], pagination: {}, not_modified: true, etag: response[:etag]) if response[:not_modified]

      body = response[:json]
      Page.new(data: Array(body["data"]), pagination: body["pagination"] || {},
        not_modified: false, etag: response[:etag])
    end

    def get_single(path)
      response = get(path, {}, collection: false, conditional: false)
      return { data: nil, not_modified: true } if response[:not_modified]

      { data: response[:json]["data"] || {}, not_modified: false }
    end

    # Low-level GET with ETag, auth, rate-limit, timeout, and circuit handling.
    # Never logs the token or the Authorization header.
    def get(path, query, collection:, conditional: true)
      raise NotConfiguredError, "PerfectBook API token is not configured" if @api_token.blank?
      raise CircuitOpenError, "PerfectBook circuit is open; skipping request" unless Circuit.allow_request?

      uri = URI.join("#{@base_url}/", path.sub(%r{\A/}, ""))
      uri.query = URI.encode_www_form(query) if query.any?
      cache_key = "GET #{uri.path}#{uri.query ? "?#{uri.query}" : ""}"
      headers = { "Accept" => "application/json" }
      sent_etag = @etag_store.read(cache_key) if conditional
      headers["If-None-Match"] = sent_etag if sent_etag.present?

      if @pace_requests && @last_request_at
        delay = 0.6 - (Process.clock_gettime(Process::CLOCK_MONOTONIC) - @last_request_at)
        sleep(delay) if delay.positive?
      end
      @last_request_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      started = Time.current
      http_response = perform_request(uri, headers)
      elapsed = ((Time.current - started) * 1000).round
      Rails.logger.info("PerfectBook GET #{uri.path} -> #{http_response.code} (#{elapsed}ms)")

      case http_response.code.to_i
      when 200
        Circuit.record_success
        etag = http_response["ETag"]
        { json: JSON.parse(http_response.body.to_s), etag: etag.present? ? [ cache_key, etag ] : nil, not_modified: false }
      when 304
        Circuit.record_success
        { json: nil, etag: sent_etag, not_modified: true }
      when 400, 406
        raise BadRequestError, safe_message(http_response)
      when 401
        raise UnauthorizedError, "PerfectBook rejected the API token"
      when 404
        # The whole API 404s when PerfectBook has no token configured.
        # Collection reads surface that; member reads surface a missing row.
        if collection
          raise NotConfiguredError, "PerfectBook API is not configured (404)"
        else
          raise NotFoundError, safe_message(http_response)
        end
      when 429
        raise RateLimitedError.new("PerfectBook rate limit reached", retry_after: retry_after(http_response))
      when 500..599
        Circuit.record_failure
        raise UnavailableError, "PerfectBook is unavailable (#{http_response.code})"
      else
        raise Error, safe_message(http_response)
      end
    rescue RateLimitedError => e
      raise unless @pace_requests

      sleep([ e.retry_after || 60, 0.6 ].max)
      retry
    rescue Net::OpenTimeout, Net::ReadTimeout => e
      Circuit.record_failure
      raise UnavailableError, "PerfectBook timed out (#{e.class})"
    rescue SocketError, SystemCallError, IOError, OpenSSL::SSL::SSLError => e
      Circuit.record_failure
      raise UnavailableError, "PerfectBook connection failed (#{e.class})"
    rescue JSON::ParserError => e
      raise Error, "PerfectBook returned invalid JSON"
    end

    def perform_request(uri, headers)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = OPEN_TIMEOUT
      http.read_timeout = READ_TIMEOUT
      request = Net::HTTP::Get.new(uri.request_uri, headers)
      request["Authorization"] = "Bearer #{@api_token}"
      http.request(request)
    end

    def safe_message(http_response)
      body = http_response.body.to_s
      parsed = JSON.parse(body) rescue nil
      err = parsed.is_a?(Hash) ? parsed["error"].to_s : ""
      err.presence || "PerfectBook request failed (#{http_response.code})"
    end

    def retry_after(http_response)
      raw = http_response["Retry-After"].to_s
      Integer(raw, exception: false)
    end

    def build_contact(row)
      Contact.new(
        id: row["id"], kind: row["kind"], name: row["name"], email: row["email"],
        phone: row["phone"], country: row["country"], state: row["state"],
        archived: row["archived"], created_at: row["created_at"], updated_at: row["updated_at"]
      )
    end

    def build_trip(row)
      Trip.new(
        id: row["id"], name: row["name"], active: row["active"], status: row["status"],
        shopify_product_id: row["shopify_product_id"]&.to_s,
        departures_count: row["departures_count"], departure_ids: Array(row["departure_ids"]),
        first_start_date: row["first_start_date"], last_end_date: row["last_end_date"],
        created_at: row["created_at"], updated_at: row["updated_at"]
      )
    end

    def build_departure(row)
      Departure.new(
        id: row["id"], trip_id: row["trip_id"], trip_name: row["trip_name"], label: row["label"],
        start_date: row["start_date"], end_date: row["end_date"], duration_days: row["duration_days"],
        place: row["place"], country_codes: Array(row["country_codes"]), status: row["status"],
        seats: row["seats"], booked_seats: row["booked_seats"], available_seats: row["available_seats"],
        price_per_person_minor: row["price_per_person_minor"], currency: row["currency"] || "USD",
        created_at: row["created_at"], updated_at: row["updated_at"]
      )
    end

    def build_booking(row)
      trip = row["trip"] || {}
      departure = row["departure"] || {}
      invoice = row["invoice"] || {}
      documents = row["documents"] || {}
      Booking.new(
        id: row["id"], ref: row["ref"], status: row["status"],
        trip_id: trip["id"], trip_name: trip["name"],
        departure_id: departure["id"], departure_place: departure["place"],
        start_date: departure["start_date"], end_date: departure["end_date"],
        party_size: row["party_size"], price_per_person_minor: row["price_per_person_minor"],
        total_minor: row["total_minor"], paid_minor: row["paid_minor"],
        balance_due_minor: row["balance_due_minor"], currency: row["currency"] || "USD",
        invoice_badge: invoice["badge"], invoice_number: invoice["number"],
        payment_reference: invoice["payment_reference"], deep_link: row["deep_link"],
        documents: documents, checklist: Array(row["checklist"]),
        missing_count: documents["missing_count"].to_i
      )
    end

    def build_upload_result(body)
      data = body["data"] || {}
      traveler = data["traveler"] || {}
      document = data["document"] || {}
      UploadResult.new(
        traveler_id: traveler["id"], traveler_name: traveler["first_name"],
        document_type: document["type"], document_status: document["status"],
        received_at: document["received_at"],
        missing_count: data["missing_count"].to_i,
        duplicate: data["duplicate"] == true
      )
    end

    def perform_upload(booking_ref, traveler_id, file:, filename:, content_type:, document_type:, upload_id:)
      parts = [
        { name: "document_type", data: document_type.to_s, filename: nil, content_type: nil },
        { name: "upload_id", data: upload_id.to_s, filename: nil, content_type: nil },
        { name: "file", data: file, filename: filename.to_s, content_type: content_type.to_s }
      ]
      boundary = "----PerfectCRM#{SecureRandom.hex(16)}"
      body = build_multipart(parts, boundary)
      path = "/api/v1/bookings/#{URI.encode_uri_component(booking_ref.to_s)}/travelers/#{URI.encode_uri_component(traveler_id.to_s)}/documents"
      uri = URI.join("#{@base_url}/", path.sub(%r{\A/}, ""))
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = OPEN_TIMEOUT
      http.read_timeout = READ_TIMEOUT
      request = Net::HTTP::Post.new(uri.request_uri)
      request["Accept"] = "application/json"
      request["Authorization"] = "Bearer #{@api_token}"
      request["Content-Type"] = "multipart/form-data; boundary=#{boundary}"
      request.body = body
      http.request(request)
    end

    def build_multipart(parts, boundary)
      chunks = parts.map do |part|
        header = +"--#{boundary}\r\nContent-Disposition: form-data; name=\"#{part[:name]}\"".b
        if part[:filename].present?
          filename = part[:filename].gsub(/["\\\r\n]/) { |char| "%%%02X" % char.ord }
          header << "; filename=\"#{filename}\"".b
        end
        header << "\r\nContent-Type: #{part[:content_type]}".b if part[:content_type].present?
        header << "\r\n\r\n".b
        header + part[:data].to_s.b + "\r\n".b
      end
      chunks.join.b + "--#{boundary}--\r\n".b
    end
  end
end
