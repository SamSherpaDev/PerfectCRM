# Read-only Microsoft Graph reader for the captain's Microsoft 365 mailbox.
#
# Replaces the retired Gmail IMAP reader (basic auth is disabled
# tenant-wide, so no password can open the mailbox). Reads via delegated
# OAuth: inherently limited to the captain's own mailbox. Never modifies or
# flags anything server-side: only GET requests, no PATCH/POST/DELETE.
#
# Incremental sync uses the messages delta endpoint per folder, persisting
# the @odata.deltaLink per folder in MailSyncState. Microsoft 365 has no
# single All Mail equivalent, so EVERY mail folder is watched, child folders
# included, exactly like the history backfill: a server-side rule can file
# operator mail at delivery so it never touches the Inbox, and mail that
# reaches no folder's delta reaches no timeline. Only folders that hold no
# correspondence are left out (SKIPPED_FOLDERS). The folder list is re-read
# on every run, so a folder created in Outlook starts being watched without
# a reconnect. Delta quirks handled: @removed entries are skipped, and
# entries already stored (a read-state toggle, or a replay after an
# uncommitted link) are skipped before their message is fetched, so nothing
# is downloaded twice.
#
# Privacy: the info@ hard filter (Mail.keeps?, enforced again in the
# ingester) decides what is stored, and no attachment bytes move until it
# has. The two paths reach that decision differently, and the difference is
# worth stating exactly. The history walk judges straight off the folder
# listing, which carries the recipient fields, so personal mail in a folder
# is never opened at all. Live sync GETs the message first - body included,
# because that same GET is what carries the delivery headers it judges on -
# so a personal message's body is read into memory and dropped, never
# stored and never logged. Attachment bytes come from the attachments
# endpoint one file at a time, lazily, only when a kept message is actually
# being stored.
#
# That split narrows the backfill on purpose: Microsoft documents
# internetMessageHeaders as retrievable with $select on a GET of a single
# message, not on a folder listing, so the walk matches on from, To, Cc and
# Bcc and live sync applies the full six-header check. Guessing at an
# undocumented listing $select is not worth downloading every personal
# message body to compensate.
#
# First-run safety: a fresh connect primes each folder's delta link with an
# initial delta call that is drained but NOT ingested, so ongoing sync
# starts from now and history stays for the import screen, where the
# captain chooses depth with a preview. A folder that appears later is
# primed the same way rather than backfilled unasked, and says so through a
# MailSyncState notice so the captain can import its past mail deliberately.
#
# Nothing here is allowed to fail quietly: a folder whose sync raises is
# recorded against that folder and the run carries on with the rest before
# reporting, and a delta token Graph invalidates (410) is re-primed AND
# caught up from the last committed sync, so the window the dead token
# covered is refilled instead of dropped. That catch-up is capped at
# RECOVERY_WINDOW; a longer outage is reported rather than walked, because
# opening months of the captain's mail on his behalf is the import screen's
# decision to offer him, not this reader's to take.
module Mail
  class GraphFetcher
    # Folders neither the live sync nor the backfill reads, children included.
    SKIPPED_FOLDERS = %w[deleteditems junkemail drafts outbox conversationhistory].freeze
    PAGE_SIZE = 50
    # How far back a 410 recovery will re-read a folder in one run. Sized to
    # what a run can comfortably finish: it opens every message in the
    # window, SyncJob stores at most its own cap per run, and the whole run
    # has to fit inside SyncJob::CONCURRENCY_WINDOW. A day of one mailbox's
    # mail sits well inside both; a longer gap is the captain's call to make
    # through Import history, with a preview, rather than an invisible
    # download of months of his mail.
    RECOVERY_WINDOW = 24.hours

    MESSAGE_SELECT = %w[
      id internetMessageId conversationId categories from toRecipients
      ccRecipients bccRecipients subject body receivedDateTime
      sentDateTime hasAttachments isRead internetMessageHeaders
    ].join(",").freeze
    # The folder listing carries enough to judge a message without opening
    # it: everything Mail.keeps? looks at bar the delivery headers.
    HISTORY_SELECT = "id,receivedDateTime,from,toRecipients,ccRecipients,bccRecipients".freeze
    FOLDER_SELECT = "id,displayName,wellKnownName,childFolderCount".freeze
    ATTACHMENT_SELECT = "id,name,contentType,size,isInline".freeze
    # The documented shape for reading a forwarded message: one level, no
    # $select inside the cast.
    ITEM_EXPAND = "microsoft.graph.itemAttachment/item".freeze

    Fetched = Struct.new(:parsed, :provider, :folder, :cursor, keyword_init: true)
    Folder = Struct.new(:id, :name, keyword_init: true)

    # Attachment bytes are downloaded on first read. The import preview
    # walks the whole mailbox but only reads counterparties, so it pays for
    # metadata alone; the commit path reads the entries and materializes.
    class LazyAttachments
      def initialize(&materialize)
        @materialize = materialize
      end

      def to_a
        @entries ||= Array(@materialize.call)
      end
    end

    def initialize(transport: GraphTransport.new)
      @transport = transport
    end

    def configured?
      GraphAuth.configured? && ::Setting.current.ms_graph_refresh_token.present?
    end

    # Cheap connectivity check for Settings "Test connection".
    def test_connection
      raise NotConfiguredError, "Connect the mailbox in Settings first." unless configured?

      client.get_json("/me", params: { "$select" => "id,mail,userPrincipalName" })
      true
    end

    # Incremental delta sync across every watched folder. Yields Fetched
    # structs for kept messages only and commits each folder's new deltaLink
    # after a full drain; a mid-folder failure leaves the old link so the
    # next run replays and skips what it already stored. Folders without a
    # link are primed, not ingested, so a folder that appears later starts
    # from now rather than backfilling itself unasked. One folder's failure
    # is recorded against that folder and never starves the folders after
    # it: every folder is attempted, then the first failure is raised so the
    # run reads as partial rather than complete. Callers cap stored volume
    # themselves (see SyncJob): stopping early leaves the link uncommitted
    # for replay.
    def fetch_new
      raise NotConfiguredError, "Mailbox is not connected." unless configured?
      return enum_for(:fetch_new) unless block_given?

      graph = client
      folders = mail_folders(graph)
      states = register_folders(folders)
      failure = nil
      folders.each do |folder|
        state = states.fetch(folder)
        if state.delta_link.blank?
          announce = state.announce?
          prime_folder(graph, folder)
          announce_new_folder(folder) if announce
          next
        end
        drain_delta(graph, folder, state) do |parsed, provider|
          yield Fetched.new(parsed: parsed, provider: provider, folder: folder.id)
        end
      rescue NotConfiguredError, GrantRevokedError
        raise
      rescue GraphError => e
        # The captain reads one error line, so it has to name its folder
        # wherever it surfaces: against the folder here, and in the failure
        # the run raises, which is what SyncJob copies onto the mailbox card.
        message = "#{folder.name}: #{e.message}"
        ::MailSyncState.record_error!(folder.id, message)
        failure ||= e.class.new(message)
      end
      raise failure if failure
    end

    # History walk for preview/import: $filter=receivedDateTime ge {date}
    # over every folder the backfill covers, oldest first. Messages are
    # judged from the listing and only the keepers are opened, so no
    # personal message body is ever fetched. Yields Fetched structs with an
    # opaque cursor ("folder|receivedDateTime"); resuming restarts at that
    # folder and replays that whole second, because Graph promises no order
    # among messages sharing a receivedDateTime and a resume that assumed
    # one would drop the mail it ordered differently. The replayed messages
    # dedupe on the provider message id.
    def fetch_history(since: nil, cursor: nil)
      raise NotConfiguredError, "Mailbox is not connected." unless configured?
      return enum_for(:fetch_history, since: since, cursor: cursor) unless block_given?

      resume = parse_cursor(cursor)
      graph = client
      folders = mail_folders(graph)
      resumed_at = resume ? folders.index { |folder| folder.id == resume[:folder] } : nil
      folders.each_with_index do |folder, position|
        next if resumed_at && position < resumed_at

        walk_folder(graph, folder.id, floor_for(folder.id, since, resume)) do |parsed, provider, entry|
          yield Fetched.new(parsed: parsed, provider: provider, folder: folder.id,
            cursor: "#{folder.id}|#{entry_time(entry).utc.iso8601}")
        end
      end
    end

    private

    def client
      GraphClient.new(transport: @transport) { GraphAuth.access_token!(transport: @transport) }
    end

    def delta_headers
      { "Prefer" => "odata.maxpagesize=#{PAGE_SIZE}" }
    end

    # Every folder the reader watches, in a stable order so a resumed import
    # lands in the same place. Skipped folders take their children with
    # them: a subfolder of Deleted Items is still deleted mail.
    def mail_folders(client)
      collect_folders(client, "#{GraphClient::BASE}/me/mailFolders?#{folder_params}").sort_by(&:id)
    end

    def collect_folders(client, url)
      found = []
      while url.present?
        page = client.get_json(url)
        Array(page["value"]).each do |folder|
          id = folder["id"].to_s
          next if id.blank? || SKIPPED_FOLDERS.include?(folder["wellKnownName"].to_s.downcase)

          found << Folder.new(id: id, name: folder["displayName"].to_s.presence || id)
          next unless folder["childFolderCount"].to_i.positive?

          found.concat(collect_folders(client, "#{GraphClient::BASE}/me/mailFolders/#{id}/childFolders?#{folder_params}"))
        end
        url = page["@odata.nextLink"]
      end
      found
    end

    # Every folder the enumeration just returned gets its row here, in one
    # transaction, before any of them is primed. That is what makes the
    # three folder states a lookup instead of a guess: a row exists for
    # every folder the mailbox has ever shown us, so a folder without one is
    # genuinely new, and a run that dies part-way through priming can no
    # longer leave a folder that was always there row-less for the next run
    # to greet as new.
    def register_folders(folders)
      ::MailSyncState.transaction do
        enumerated_before = ::MailSyncState.exists?
        folders.index_with do |folder|
          ::MailSyncState.for(folder.id, discovered: enumerated_before)
        end
      end
    end

    # A folder that shows up after the mailbox is already syncing is watched
    # from now, never backfilled on its own: it can hold years of archived
    # mail, and choosing that depth is the import screen's job. Saying so
    # here is what keeps the choice in front of the captain.
    def announce_new_folder(folder)
      ::MailSyncState.record_discovery!(folder.id,
        "New folder #{folder.name}: watched from now. Run Import history to bring in mail it already holds.")
    end

    def folder_params
      URI.encode_www_form("$select" => FOLDER_SELECT, "$top" => PAGE_SIZE)
    end

    def delta_url(folder)
      "#{GraphClient::BASE}/me/mailFolders/#{folder}/messages/delta?$select=#{URI.encode_www_form_component("id")}"
    end

    # The resume timestamp belongs to the folder its cursor names. Applying
    # it to a later folder would silently skip that folder's older mail.
    def floor_for(folder, since, resume)
      floors = [ since&.to_time ]
      floors << resume[:at] if resume && resume[:folder] == folder
      floors.compact.max
    end

    # Recipient fields as the folder listing returns them. The delivery
    # headers are missing here by design (see the note at the top), so this
    # rule alone cannot see a hidden-Bcc arrival: the backfill accepts that
    # and leaves such mail to live sync, which reads the full headers.
    def listed_recipients(entry)
      {
        "from" => addresses_of(entry["from"]),
        "to" => addresses_of(entry["toRecipients"]),
        "cc" => addresses_of(entry["ccRecipients"]),
        "bcc" => addresses_of(entry["bccRecipients"])
      }
    end

    def history_url(folder, floor)
      params = {
        "$select" => HISTORY_SELECT,
        "$orderby" => "receivedDateTime asc",
        "$top" => PAGE_SIZE
      }
      params["$filter"] = "receivedDateTime ge #{floor.utc.iso8601}" if floor
      "#{GraphClient::BASE}/me/mailFolders/#{folder}/messages?#{URI.encode_www_form(params)}"
    end

    # Pages one folder's message listing from a floor.
    #
    # screen_listing is the backfill's deliberately narrower rule: judge
    # from the recipient fields the listing carries and never open what it
    # rejects, so a mailbox-wide walk costs no personal message bodies. Gap
    # recovery turns it off, because a listing cannot carry a delivery
    # header and this is live sync's own window - the mail it covers gets
    # no second chance, so a hidden-Bcc arrival must be judged the way live
    # sync judges it, on load_message's full header check.
    def walk_folder(client, folder, floor, screen_listing: true, skip_stored: false)
      url = history_url(folder, floor)
      loop do
        page = client.get_json(url)
        Array(page["value"]).each do |entry|
          next if entry["@removed"] || entry["id"].blank?
          next if screen_listing && !Mail.keeps?(listed_recipients(entry))
          next if skip_stored && ::Message.exists?(provider_message_id: entry["id"])

          loaded = load_message(client, entry["id"])
          next if loaded.nil?

          yield(*loaded, entry)
        end
        url = page["@odata.nextLink"]
        break if url.blank?
      end
    end

    # Initial delta call, drained for its deltaLink and never ingested. The
    # drain is separate from the commit because gap recovery must not
    # persist the new link until it has actually read the gap.
    def drain_prime(client, folder)
      url = delta_url(folder)
      delta_link = nil
      loop do
        page = client.get_json(url, headers: delta_headers)
        delta_link = page["@odata.deltaLink"] if page["@odata.deltaLink"].present?
        url = page["@odata.nextLink"]
        break if url.blank?
      end
      delta_link
    end

    def prime_folder(client, folder)
      ::MailSyncState.for(folder.id).update!(delta_link: drain_prime(client, folder.id),
        last_sync_at: Time.current, last_error: nil, last_error_at: nil)
    end

    # Drains one folder's delta, committing the new link at the end.
    # Entries already stored are skipped before their message is fetched:
    # Graph reports every change (a read-state toggle counts), and an
    # uncommitted link replays the whole page on the next run.
    def drain_delta(client, folder, state)
      folder_id = folder.id
      url = state.delta_link
      last_page = nil
      loop do
        last_page = client.get_json(url, headers: delta_headers)
        Array(last_page["value"]).each do |entry|
          next if entry["@removed"]
          next if entry["id"].blank?
          next if ::Message.exists?(provider_message_id: entry["id"])

          loaded = load_message(client, entry["id"])
          next if loaded.nil?

          yield(*loaded)
        end
        url = last_page["@odata.nextLink"]
        break if url.blank?
      end
      delta_link = last_page["@odata.deltaLink"]
      ::MailSyncState.record_success!(folder_id, delta_link: delta_link.presence || state.delta_link)
    rescue GraphClient::GoneError
      # Sync token expired server-side. Re-priming alone would drop every
      # message that arrived since the last committed link, so the window
      # between that link and now is walked as well; the ingester's dedupe
      # discards the overlap. Bounded by the last successful sync, so a
      # stale token still cannot backfill the whole mailbox unasked.
      recover_gap(client, folder, state.last_sync_at) { |*loaded| yield(*loaded) }
    end

    # The gap the dead token covered is read BEFORE the replacement link is
    # committed. An interrupted recovery - a failure, or a caller that stops
    # on its run limit - therefore leaves the dead token in place, so the
    # next run meets the same 410 and replays the whole window instead of
    # losing whatever it had not reached yet.
    #
    # Past RECOVERY_WINDOW the gap is reported instead of walked: sync
    # resumes from now so the folder is not stuck on a dead token, and the
    # captain is told how far back to import.
    def recover_gap(client, folder, since)
      delta_link = drain_prime(client, folder.id)
      return report_long_gap(folder, since, delta_link) if since < RECOVERY_WINDOW.ago

      walk_folder(client, folder.id, since, screen_listing: false, skip_stored: true) do |parsed, provider, _entry|
        yield(parsed, provider)
      end
      ::MailSyncState.record_success!(folder.id, delta_link: delta_link)
      ::MailSyncState.record_notice!(folder.id,
        "#{folder.name}: Microsoft expired this folder's sync token; mail since #{since.utc.iso8601} was re-read to fill the gap.")
    end

    # The notice says exactly what an import can and cannot bring back. The
    # backfill judges from the folder listing, which carries no delivery
    # header, so mail that reached the mailbox only as a hidden copy is not
    # among what it recovers - and promising otherwise would send the
    # captain looking for mail that is not going to appear.
    def report_long_gap(folder, since, delta_link)
      ::MailSyncState.record_success!(folder.id, delta_link: delta_link)
      ::MailSyncState.record_notice!(folder.id,
        "#{folder.name}: Microsoft expired this folder's sync token, and the gap back to " \
        "#{since.utc.iso8601} is longer than #{RECOVERY_WINDOW.inspect}. Watching from now. " \
        "Import history since #{since.to_date} brings back mail naming #{Mail.mailbox_address} in " \
        "From, To, Cc or Bcc; mail that reached the mailbox only as a hidden copy is not recovered that way.")
      nil
    end

    # Full message GET (metadata + attachment listing), keeps?-filtered
    # before any attachment bytes can move. Returns [parsed, provider] or
    # nil for gone/filtered messages.
    def load_message(client, id)
      json = client.get_json("/me/messages/#{id}",
        params: {
          "$select" => MESSAGE_SELECT,
          "$expand" => "attachments($select=#{ATTACHMENT_SELECT})"
        })
      headers = recipient_headers(json)
      return nil unless Mail.keeps?(headers)

      parsed = parsed_from(client, json, headers)
      provider = {
        message_id: json["id"].to_s,
        thread_id: json["conversationId"].to_s.presence,
        labels: Array(json["categories"]).map(&:to_s)
      }
      [ parsed, provider ]
    rescue GraphClient::NotFoundError
      nil
    end

    # Real recipient headers only: Graph's own recipient lists plus the
    # delivery headers a hidden Bcc leaves behind (a Bcc copy still shows
    # the original To). Nothing here is synthesized, so a message that
    # names the mailbox only in Reply-To or a list header is not kept.
    def recipient_headers(json)
      {
        "from" => addresses_of(json["from"]),
        "to" => addresses_of(json["toRecipients"]),
        "cc" => addresses_of(json["ccRecipients"]),
        "bcc" => addresses_of(json["bccRecipients"]),
        "delivered-to" => header_values(json, "Delivered-To"),
        "x-original-to" => header_values(json, "X-Original-To")
      }
    end

    def parsed_from(client, json, headers)
      from = addresses_of(json["from"])
      to = addresses_of(json["toRecipients"])
      cc = addresses_of(json["ccRecipients"])
      body = json["body"] || {}
      html = body["contentType"].to_s.casecmp?("html")
      message_id = json["id"].to_s
      attachments = Array(json["attachments"])
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
        text_body: html ? nil : body["content"].to_s.presence,
        html_body: html ? body["content"].to_s.presence : nil,
        attachments: LazyAttachments.new { attachment_entries(client, message_id, attachments) },
        raw_size: body["content"].to_s.bytesize
      )
    end

    def attachment_entries(client, message_id, attachments)
      entries = []
      Array(attachments).each do |attachment|
        name = attachment["name"].to_s.presence || "attachment"
        content_type = attachment["contentType"].to_s.presence || "application/octet-stream"
        if attachment["@odata.type"].to_s.include?("itemAttachment")
          entry = forwarded_entry(client, message_id, attachment, name)
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
    def forwarded_entry(client, message_id, attachment, name)
      nested = client.get_json("/me/messages/#{message_id}/attachments/#{attachment["id"]}",
        params: { "$expand" => ITEM_EXPAND })
      item = nested["item"]
      return nil if item.blank?

      eml, screened = build_forward_mime(item)
      { filename: eml_name(name), content_type: "message/rfc822", data: eml, sensitive: !screened }
    rescue GraphClient::NotFoundError
      nil
    end

    # Rebuilds one forwarded message as MIME from whatever Graph handed
    # back. Returns the bytes and whether everything inside could be read:
    # an enclosure with no bytes, a forward enclosed in this one, or a
    # missing attachment list on a forward that says it has attachments all
    # mean the contents could not be screened, and an unscreened forward is
    # held whole rather than stored as a download.
    def build_forward_mime(item)
      body = item["body"] || {}
      from = addresses_of(item["from"]).first
      to = addresses_of(item["toRecipients"])
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
      enclosures = Array(item["attachments"])
      screened = !(item["hasAttachments"] && enclosures.empty?)
      enclosures.each do |nested|
        content = nested["contentBytes"].to_s
        if content.blank?
          screened = false
          next
        end

        mail.add_file(filename: nested["name"].to_s.presence || "attachment",
          content: Base64.decode64(content))
      end
      [ mail.to_s, screened ]
    end

    def eml_name(name)
      name.downcase.end_with?(".eml") ? name : "#{name}.eml"
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

      folder, iso = cursor.to_s.split("|", 2)
      return nil if folder.blank?

      at = parse_time(iso)
      return nil if at.nil?

      { folder: folder, at: at }
    end
  end
end
