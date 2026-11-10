# Retries, every hour (Solid Queue, see config/recurring.yml), the mail live
# sync set aside after MailMessageQuarantine::MAX_ATTEMPTS failed reads, for
# as long as it takes each one to read. Being set aside is how one unreadable
# message stops holding up its folder; this is what makes it temporary, so
# mail set aside by an outage or a bad deploy arrives on its own afterwards.
# Stored exactly as live sync stores it. A message that still fails stays on
# the list, which the Settings mailbox card counts; nothing is raised for it.
class Mail::SetAsideRetryJob < ApplicationJob
  queue_as :default

  limits_concurrency(**Mail::SyncJob::MAILBOX_GUARD)

  # Messages tried per run. A message that never reads costs one request an
  # hour, and a backlog an outage left behind still clears within hours.
  LIMIT = 100

  def perform(fetcher: nil, limit: LIMIT)
    fetcher ||= Mail::GraphFetcher.new
    return false unless fetcher.configured?

    stored = 0
    fetcher.fetch_set_aside(limit: limit) do |item|
      stored += 1 if Mail::SyncJob.store(item)
    end
    stored
  end
end
