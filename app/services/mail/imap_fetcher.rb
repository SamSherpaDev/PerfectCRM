require "net/imap"

# Read-only IMAP fetcher for the captain's Gmail.
# Connects to imap.gmail.com:993 with the mailbox login + app password,
# examines (never selects) [Gmail]/All Mail so sent mail is included, and
# fetches incrementally by UIDVALIDITY/UID. Uses X-GM-EXT-1 attributes
# (X-GM-THRID, X-GM-MSGID, X-GM-LABELS) where the server offers them, with
# a Message-ID/In-Reply-To/References fallback in the ingester.
#
# Read-only guarantee: this class only ever calls #examine, #status,
# #uid_fetch, and #logout. It never calls #select, #store, #copy, #move,
# #expunge, or #uid_store. Covered by tests.
module Mail
  class ImapFetcher
    HOST = "imap.gmail.com"
    PORT = 993
    FOLDER = Mail::FOLDER

    Fetched = Struct.new(:uid, :uid_validity, :raw, :gmail, keyword_init: true)

    def initialize(login: nil, password: nil, imap: nil)
      @login = login.presence || ::Setting.current.mailbox_login.to_s
      @password = password.presence || ::Setting.current.mailbox_app_password.to_s
      @injected_imap = imap
    end

    def configured?
      @login.present? && @password.present?
    end

    # Cheap connectivity check for Settings "Test connection".
    def test_connection
      raise NotConfiguredError, "Add the mailbox login and app password first." unless configured?

      with_connection do |imap|
        imap.status(FOLDER, [ "UIDVALIDITY", "UIDNEXT" ])
      end
      true
    end

    # Incremental fetch: returns messages with UID above the stored cursor.
    # Updates MailSyncState on success. Resets the cursor when UIDVALIDITY
    # changes (Gmail rebuilt the folder).
    def fetch_new(limit: 200)
      raise NotConfiguredError, "Mailbox is not configured." unless configured?

      state = ::MailSyncState.for(FOLDER)
      collected = []
      with_connection do |imap|
        imap.examine(FOLDER)
        validity = imap.responses["UIDVALIDITY"]&.last || current_validity(imap)
        if state.uid_validity.present? && validity.present? && state.uid_validity != validity
          state.update!(last_uid: 0, uid_validity: validity)
        elsif validity.present? && state.uid_validity.nil?
          state.update!(uid_validity: validity)
        end
        from_uid = state.last_uid.to_i + 1
        uids = imap.uid_search([ "UID", "#{from_uid}:*" ]).first(limit)
        uids.each do |uid|
          data = fetch_one(imap, uid)
          collected << data if data
        end
        max_uid = uids.max || state.last_uid
        ::MailSyncState.record_success!(FOLDER, uid_validity: validity || state.uid_validity || 0, last_uid: max_uid)
      end
      collected
    rescue Net::IMAP::Error, SocketError, SystemCallError, IOError => e
      ::MailSyncState.record_error!(FOLDER, e.message)
      raise ConnectionError, e.message
    end

    # Full-folder scan for the history import preview/commit. Yields Fetched
    # structs; callers enforce the info@ rule via the ingester.
    def fetch_all(since: nil, limit: nil, &block)
      raise NotConfiguredError, "Mailbox is not configured." unless configured?
      return enum_for(:fetch_all, since: since, limit: limit) unless block

      with_connection do |imap|
        imap.examine(FOLDER)
        criteria = [ "ALL" ]
        criteria = [ "SINCE", since.strftime("%d-%b-%Y") ] if since
        uids = imap.uid_search(criteria)
        uids = uids.first(limit) if limit
        uids.each do |uid|
          data = fetch_one(imap, uid)
          block.call(data) if data
        end
      end
    end

    class NotConfiguredError < StandardError; end
    class ConnectionError < StandardError; end

    private

    def with_connection
      return yield @injected_imap if @injected_imap

      imap = Net::IMAP.new(HOST, port: PORT, ssl: true)
      begin
        imap.login(@login, @password)
        yield imap
      ensure
        begin
          imap.logout
        rescue StandardError
          nil
        end
        begin
          imap.disconnect
        rescue StandardError
          nil
        end
      end
    end

    def current_validity(imap)
      status = imap.status(FOLDER, [ "UIDVALIDITY" ]) rescue nil
      status&.dig("UIDVALIDITY")
    end

    def fetch_one(imap, uid)
      # X-GM-EXT-1 attributes give Gmail threading + dedupe IDs.
      items = [ "RFC822", "X-GM-THRID", "X-GM-MSGID", "X-GM-LABELS", "INTERNALDATE" ]
      begin
        rows = imap.uid_fetch([ uid ], items)
      rescue Net::IMAP::Error
        rows = imap.uid_fetch([ uid ], [ "RFC822", "INTERNALDATE" ])
      end
      row = Array(rows).first
      return nil if row.nil?

      raw = row.attr["RFC822"].to_s
      return nil if raw.blank?

      Fetched.new(
        uid: uid,
        uid_validity: imap.responses["UIDVALIDITY"]&.last,
        raw: raw,
        gmail: {
          gm_thrid: row.attr["X-GM-THRID"]&.to_s,
          gm_msgid: row.attr["X-GM-MSGID"]&.to_s,
          labels: Array(row.attr["X-GM-LABELS"]).map(&:to_s),
          delivered_to: [],
          x_original_to: []
        }
      )
    end
  end
end
