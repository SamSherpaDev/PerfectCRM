# Read-only Microsoft Graph reader for the captain's Microsoft 365 mailbox.
#
# Replaces the retired Gmail IMAP reader (basic auth is disabled
# tenant-wide, so no password can open the mailbox). Reads via delegated
# OAuth: inherently limited to the captain's own mailbox. Never modifies or
# flags anything server-side: only GET requests, no PATCH/POST/DELETE.
#
# Incremental sync uses the messages delta endpoint per folder, persisting
# the @odata.deltaLink per folder in MailSyncState. Microsoft 365 has no
# single All Mail equivalent, so BOTH Inbox and Sent Items are synced: the
# CRM must keep the captain's own replies on the timeline. Delta quirks
# handled: @removed entries are skipped, and read-state-only changes simply
# re-resolve to :duplicate in the ingester (dedupe on provider id +
# Message-ID), so nothing is ever stored twice.
#
# Privacy: the info@ hard filter (Mail.keeps?, enforced again in the
# ingester) runs on message metadata BEFORE any attachment bytes are
# fetched, so personal mail costs one metadata GET and zero attachment
# downloads. Attachment bytes come from the attachments endpoint one file
# at a time, only for kept messages.
#
# First-run safety: a fresh connect primes each folder's delta link with an
# initial delta call that is drained but NOT ingested, so ongoing sync
# starts from now and history stays for the import screen, where the
# captain chooses depth with a preview.
module Mail
  class GraphFetcher
    FOLDERS = %w[inbox sentitems].freeze
    PAGE_SIZE = 50
    # Nested forwards deeper than this lose their innermost enclosures.
    RECURSION_LIMIT = 3

    MESSAGE_SELECT = %w[
      id internetMessageId conversationId categories from toRecipients
      ccRecipients bccRecipients subject body bodyPreview receivedDateTime
      sentDateTime hasAttachments isRead internetMessageHeaders
    ].join(",").freeze
    ATTACHMENT_SELECT = "id,name,contentType,size,isInline".freeze
    NESTED_ATTACHMENT_SELECT = "id,name,contentType,size,contentBytes".freeze

    Fetched = Struct.new(:parsed, :provider, :folder, :cursor, keyword_init: true)

    def initialize(transport: GraphTransport.new)
      @transport = transport
    end

    def configured?
      GraphAuth.configured? && ::Setting.current.ms_graph_refresh_token.present?
    end

    # Cheap connectivity check for Settings "Test connection".
    def test_connection
      raise NotConfiguredError, "Connect the mailbox in Settings first." unless configured?

      with_client { |client| client.get_json("/me", params: { "$select" => "id,mail,userPrincipalName" }) }
      true
    end

    # Incremental delta sync across both folders. Yields Fetched structs for
    # kept messages only and commits each folder's new deltaLink after a
    # full drain; a mid-folder failure leaves the old link so the next run
    # replays and dedupes. Folders without a link are primed, not ingested.
    # Callers cap stored volume themselves (see SyncJob): stopping early
    # leaves the link uncommitted for replay, and the cap counts stored
    # messages so replays always make progress instead of starving.
    def fetch_new
      raise NotConfiguredError, "Mailbox is not connected." unless configured?
      return enum_for(:fetch_new) unless block_given?

      with_client do |client|
        FOLDERS.each do |folder|
          state = ::MailSyncState.for(folder)
          if state.delta_link.blank?
            prime_folder(client, folder)
            next
          end
          drain_delta(client, folder, state) do |parsed, provider|
            yield Fetched.new(parsed: parsed, provider: provider, folder: folder)
          end
        end
      end
    end

    # History walk for preview/import: $filter=receivedDateTime ge {date}
    # across Inbox and Sent Items, oldest first. Yields Fetched structs with
    # an opaque cursor ("folder|receivedDateTime|id"); resuming with a cursor
    # re-walks and skips everything at or before it, so vanished mail cannot
    # shift the resume point.
    def fetch_history(since: nil, cursor: nil)
      raise NotConfiguredError, "Mailbox is not connected." unless configured?
      return enum_for(:fetch_history, since: since, cursor: cursor) unless block_given?

      resume = parse_cursor(cursor)
      with_client do |client|
        FOLDERS.each do |folder|
          next if resume && folder_before?(folder, resume[:folder])

          floor = [ since&.to_time, resume&.dig(:at) ].compact.max
          url = history_url(folder, floor)
          loop do
            page = client.get_json(url)
            Array(page["value"]).each do |entry|
              next if entry["@removed"] || entry["id"].blank?
              next if resume && !after_cursor?(folder, entry, resume)

              loaded = load_message(client, folder, entry["id"])
              next if loaded.nil?

              parsed, provider = loaded
              yield Fetched.new(parsed: parsed, provider: provider, folder: folder,
                cursor: "#{folder}|#{entry_time(entry).iso8601(6)}|#{entry["id"]}")
            end
            url = page["@odata.nextLink"]
            break if url.blank?
          end
        end
      end
    end

    private

    def with_client
      attempts = 0
      token = GraphAuth.access_token!(transport: @transport)
      begin
        attempts += 1
        yield GraphClient.new(access_token: token, transport: @transport)
      rescue GraphClient::UnauthorizedError => e
        raise GrantRevokedError, "Mailbox access was revoked or expired. Reconnect the mailbox in Settings." if e.invalid_grant?
        raise if attempts > 1

        token = GraphAuth.access_token!(transport: @transport)
        retry
      end
    end

    def delta_headers
      { "Prefer" => "odata.maxpagesize=#{PAGE_SIZE}" }
    end

    def delta_url(folder)
      "#{GraphClient::BASE}/me/mailFolders/#{folder}/messages/delta?$select=#{URI.encode_www_form_component("id")}"
    end

    def history_url(folder, floor)
      params = {
        "$select" => "id,receivedDateTime",
        "$orderby" => "receivedDateTime asc",
        "$top" => PAGE_SIZE
      }
      params["$filter"] = "receivedDateTime ge #{floor.utc.iso8601}" if floor
      "#{GraphClient::BASE}/me/mailFolders/#{folder}/messages?#{URI.encode_www_form(params)}"
    end

    # Initial delta call: drained for its deltaLink, never ingested.
    def prime_folder(client, folder)
      url = delta_url(folder)
      delta_link = nil
      loop do
        page = client.get_json(url, headers: delta_headers)
        delta_link = page["@odata.deltaLink"] if page["@odata.deltaLink"].present?
        url = page["@odata.nextLink"]
        break if url.blank?
      end
      ::MailSyncState.for(folder).update!(delta_link: delta_link,
        last_sync_at: Time.current, last_error: nil, last_error_at: nil)
    end

    # Drains one folder's delta, committing the new link at the end.
    def drain_delta(client, folder, state)
      url = state.delta_link
      last_page = nil
      loop do
        last_page = client.get_json(url, headers: delta_headers)
        Array(last_page["value"]).each do |entry|
          next if entry["@removed"]
          next if entry["id"].blank?

          loaded = load_message(client, folder, entry["id"])
          next if loaded.nil?

          yield(*loaded)
        end
        url = last_page["@odata.nextLink"]
        break if url.blank?
      end
      delta_link = last_page["@odata.deltaLink"]
      ::MailSyncState.record_success!(folder, delta_link: delta_link.presence || state.delta_link)
    rescue GraphClient::GoneError
      # Sync token expired server-side: re-prime without ingesting, so a
      # stale link can never backfill the whole mailbox unasked.
      prime_folder(client, folder)
    end

    # Full message GET (metadata + attachment listing), keeps?-filtered
    # BEFORE attachment bytes move. Returns [parsed, provider] or nil for
    # gone/filtered messages.
    def load_message(client, folder, id)
      json = client.get_json("/me/messages/#{id}",
        params: {
          "$select" => MESSAGE_SELECT,
          "$expand" => "attachments($select=#{ATTACHMENT_SELECT})"
        })
      skeleton_headers = skeleton_headers_from(json)
      unless Mail.keeps?(skeleton_headers)
        # Hidden-Bcc delivery (see bcc_delivery?): resolved to the mailbox,
        # so record the delivery evidence where the ingester's hard gate
        # looks for it. The gate and the pre-filter then always agree.
        return nil unless bcc_delivery?(folder, json)

        skeleton_headers = skeleton_headers.merge(
          "delivered-to" => Array(skeleton_headers["delivered-to"]) + [ Mail.mailbox_address ])
      end

      parsed = parsed_from(client, json, skeleton_headers)
      provider = {
        message_id: json["id"].to_s,
        thread_id: json["conversationId"].to_s.presence,
        labels: Array(json["categories"]).map(&:to_s)
      }
      [ parsed, provider ]
    rescue GraphClient::NotFoundError
      nil
    end

    def skeleton_headers_from(json)
      {
        "from" => addresses_of(json["from"]),
        "to" => addresses_of(json["toRecipients"]),
        "cc" => addresses_of(json["ccRecipients"]),
        "bcc" => addresses_of(json["bccRecipients"]),
        "delivered-to" => header_values(json, "Delivered-To"),
        "x-original-to" => header_values(json, "X-Original-To")
      }
    end

    # Hidden-Bcc safety net: mail delivered to this mailbox without the
    # address in any recipient (Bcc copies show the original To). Only
    # applies to Inbox arrivals and requires a header trace naming the
    # mailbox (Received: for <info@…> and Exchange envelope remnants);
    # anything else still falls through to the hard filter.
    def bcc_delivery?(folder, json)
      return false unless folder == "inbox"

      blob = Array(json["internetMessageHeaders"])
        .map { |header| "#{header["name"]}: #{header["value"]}" }.join("\n")
      pattern = /(?<![a-z0-9._%+-])#{Regexp.escape(Mail.mailbox_address)}(?![a-z0-9.@-])/i
      blob.match?(pattern)
    end

    def parsed_from(client, json, headers)
      from = addresses_of(json["from"])
      to = addresses_of(json["toRecipients"])
      cc = addresses_of(json["ccRecipients"])
      body = json["body"] || {}
      html_body = body["contentType"].to_s.casecmp?("html") ? body["content"].to_s.presence : nil
      text_body = !body["contentType"].to_s.casecmp?("html") ? body["content"].to_s.presence : nil
      text_body ||= json["bodyPreview"].to_s.presence
      ::Mail::Ingester::Parsed.new(
        headers: headers,
        from_addresses: from, to_addresses: to, cc_addresses: cc,
        subject: json["subject"].to_s.strip.presence,
        # parse_raw strips the brackets via the mail gem; Graph preserves
        # them, so normalize here to keep dedupe + threading identical.
        message_id: normalize_message_id(json["internetMessageId"]),
        in_reply_to: normalize_message_id(header_values(json, "In-Reply-To").first),
        references: normalize_references(header_values(json, "References")),
        sent_at: parse_time(json["sentDateTime"] || json["receivedDateTime"]),
        text_body: text_body, html_body: html_body,
        attachments: attachment_entries(client, json["id"].to_s, Array(json["attachments"])),
        raw_size: body["content"].to_s.bytesize
      )
    end

    def attachment_entries(client, message_id, attachments, depth: 0)
      entries = []
      Array(attachments).each do |attachment|
        name = attachment["name"].to_s.presence || "attachment"
        content_type = attachment["contentType"].to_s.presence || "application/octet-stream"
        if attachment["@odata.type"].to_s.include?("itemAttachment")
          entry = forwarded_entry(client, message_id, attachment, name, depth)
          entries << entry if entry
        else
          begin
            data = client.get_bytes("/me/messages/#{message_id}/attachments/#{attachment["id"]}/$value")
            entries << { filename: name, content_type: content_type, data: data }
          rescue GraphClient::NotFoundError
            # Vanished mid-sync: skip the file, keep its siblings.
            next
          end
        end
      end
      entries
    end

    # A forwarded message (attached email) becomes an .eml entry so the
    # ingester's existing recursive screening handles it exactly like an
    # IMAP forward: safe enclosures stay downloadable inside the .eml,
    # sensitive enclosures become held placeholders, and a mixed forward
    # keeps its safe files while holding the rest.
    def forwarded_entry(client, message_id, attachment, name, depth)
      return nil if depth >= RECURSION_LIMIT

      nested = client.get_json("/me/messages/#{message_id}/attachments/#{attachment["id"]}",
        params: {
          "$expand" => "microsoft.graph.itemAttachment/item(" \
            "$select=subject,from,toRecipients,body,internetMessageId;" \
            "$expand=microsoft.graph.message/attachments($select=#{NESTED_ATTACHMENT_SELECT}))"
        })
      item = nested["item"] || {}
      eml = build_forward_mime(item)
      filename = name.downcase.end_with?(".eml") ? name : "#{name}.eml"
      { filename: filename, content_type: "message/rfc822", data: eml }
    rescue GraphClient::NotFoundError
      nil
    end

    def build_forward_mime(item)
      from = addresses_of(item["from"]).first
      to = addresses_of(item["toRecipients"])
      body = item["body"] || {}
      mail = ::Mail.new
      mail.from = from if from.present?
      mail.to = to if to.any?
      mail.subject = item["subject"].to_s.presence || "(forwarded message)"
      mail.message_id = item["internetMessageId"].to_s.presence || "<#{SecureRandom.uuid}@forwarded>"
      if body["contentType"].to_s.casecmp?("html")
        mail.html_part = ::Mail::Part.new(content_type: "text/html; charset=UTF-8", body: body["content"].to_s)
      else
        mail.body = body["content"].to_s
      end
      Array(item["attachments"]).each do |nested|
        # Deeper forwards are not addressable for bytes; skip them.
        next if nested["@odata.type"].to_s.include?("itemAttachment")

        content = nested["contentBytes"].to_s
        next if content.blank?

        mail.add_file(filename: nested["name"].to_s.presence || "attachment",
          content: Base64.decode64(content))
      end
      mail.to_s
    end

    # Strip the surrounding brackets Graph preserves, matching parse_raw.
    def normalize_message_id(value)
      value.to_s.strip.gsub(/\A<+|>+\z/, "").presence
    end

    def normalize_references(values)
      Array(values).flat_map { |value| value.to_s.split }
        .filter_map { |token| normalize_message_id(token) }
        .join(" ").presence
    end

    # Graph's from is a single recipient object; the recipient lists are
    # arrays. Both shapes collapse to downcased address strings.
    def addresses_of(recipients)
      list = recipients.is_a?(Hash) ? [ recipients ] : Array(recipients)
      list.filter_map do |recipient|
        address = recipient.is_a?(Hash) ? (recipient.dig("emailAddress", "address") || recipient["address"]) : recipient
        address.to_s.strip.downcase.presence
      end
    end

    def header_values(json, name)
      Array(json["internetMessageHeaders"])
        .select { |header| header["name"].to_s.casecmp?(name) }
        .map { |header| header["value"].to_s }
    end

    def parse_time(value)
      Time.parse(value.to_s)
    rescue ArgumentError, TypeError
      nil
    end

    def entry_time(entry)
      parse_time(entry["receivedDateTime"]) || Time.at(0)
    end

    def parse_cursor(cursor)
      return nil if cursor.blank?

      folder, iso, id = cursor.to_s.split("|", 3)
      return nil unless FOLDERS.include?(folder) && id.present?

      at = parse_time(iso)
      return nil if at.nil?

      { folder: folder, at: at, id: id }
    end

    def folder_before?(folder, resume_folder)
      FOLDERS.index(folder) < FOLDERS.index(resume_folder)
    end

    def after_cursor?(folder, entry, resume)
      return true unless folder == resume[:folder]

      at = entry_time(entry)
      at > resume[:at] || (at == resume[:at] && entry["id"].to_s > resume[:id])
    end
  end
end
