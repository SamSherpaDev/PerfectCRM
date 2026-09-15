# Polls Gmail every 5 minutes over [Gmail]/All Mail (Solid Queue, see
# config/recurring.yml). Incremental by UIDVALIDITY/UID per folder, threaded
# on X-GM-THRID / X-GM-MSGID with a Message-ID fallback. Read-only IMAP:
# never moves, deletes, or flags server mail. Skips personal mail that does
# not mention the info@ mailbox without storing it.
class Mail::SyncJob < ApplicationJob
  queue_as :default

  def perform(fetcher: nil, limit: 200)
    fetcher ||= Mail::ImapFetcher.new
    return false unless fetcher.configured?

    fetched = fetcher.fetch_new(limit: limit)
    stored = 0
    fetched.each do |item|
      parsed = Mail::Ingester.parse_raw(item.raw)
      # Enrich header rule with Gmail envelope hints when present.
      result = Mail::Ingester.ingest(parsed: parsed, gmail: item.gmail)
      stored += 1 if result[:status] == :stored
    end
    ::Setting.current.update_columns(mailbox_last_sync_at: Time.current, updated_at: Time.current)
    stored
  rescue Mail::ImapFetcher::NotConfiguredError
    false
  rescue Mail::ImapFetcher::ConnectionError => e
    ::Setting.current.update_columns(mailbox_last_error: e.message.to_s.truncate(500),
      mailbox_last_error_at: Time.current, updated_at: Time.current)
    raise
  end
end
