# 7am Pacific digest: today's follow-ups, overdue, replies waiting, and
# departures to watch. Skipped when the captain turns the digest off in
# Settings. Plain and short, with deep links back into the app.
class TodayDigestJob < ApplicationJob
  queue_as :default

  def perform
    return unless Setting.current.digest_enabled?

    CaptainDigestMailer.morning.deliver_now
  end
end
