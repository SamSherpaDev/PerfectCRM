# Polls the Microsoft 365 mailbox every 5 minutes over every mail folder,
# child folders included (Solid Queue, see config/recurring.yml).
# Incremental by per-folder delta links, threaded on the Graph conversationId with a
# Message-ID/In-Reply-To/References fallback. Read-only Graph access: only
# GET requests, never moves, deletes, or flags server mail. Skips personal
# mail that does not mention the info@ mailbox without storing it.
class Mail::SyncJob < ApplicationJob
  queue_as :default

  def perform(fetcher: nil, limit: 200)
    fetcher ||= Mail::GraphFetcher.new
    return false unless fetcher.configured?

    stored = 0
    fetcher.fetch_new do |item|
      # Cap stored messages per run; replays are free, so the frontier
      # always advances instead of starving behind already-seen mail.
      break if stored >= limit

      result = Mail::Ingester.ingest(parsed: item.parsed, provider: item.provider)
      stored += 1 if result[:status] == :stored
    end
    ::Setting.current.update_columns(mailbox_last_sync_at: Time.current,
      mailbox_last_error: nil, mailbox_last_error_at: nil, updated_at: Time.current)
    stored
  rescue Mail::NotConfiguredError
    false
  rescue Mail::GrantRevokedError => e
    # Revoked or expired grant: record it for Settings ("Reconnect mailbox")
    # and stop quietly instead of retrying a dead grant.
    ::Setting.current.update_columns(mailbox_last_error: e.message.to_s.truncate(500),
      mailbox_last_error_at: Time.current, updated_at: Time.current)
    false
  rescue Mail::ConnectionError => e
    ::Setting.current.update_columns(mailbox_last_error: e.message.to_s.truncate(500),
      mailbox_last_error_at: Time.current, updated_at: Time.current)
    raise
  end
end
