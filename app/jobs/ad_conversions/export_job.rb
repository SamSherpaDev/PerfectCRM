# Nightly sweep (config/recurring.yml): records every lead outcome reached
# since the last run, sends due Meta events (new ones and backed-off
# retries), and writes a one-line result for the Settings card. Google
# reads the recorded rows itself through the scheduled feed.
class AdConversions::ExportJob < ApplicationJob
  queue_as :default

  limits_concurrency to: 1, key: "ad-conversions-export", duration: 30.minutes

  def perform(now: Time.current)
    settings = Setting.current
    return unless AdConversions.enabled?(settings)

    recorded = 0
    Lead.where("created_at >= ?", now - AdConversions::LOOKBACK).includes(:tags).find_each do |lead|
      recorded += AdConversions.record!(lead, now: now).size
    end

    meta = Hash.new(0)
    AdConversion.where(meta_status: %w[pending sending failed]).includes(lead: :tags).find_each do |row|
      result = AdConversions.deliver_meta!(row, settings: settings, now: now)
      meta[result] += 1 if result
    end

    settings.update_columns(
      ad_export_last_run_at: now,
      ad_export_last_summary: summary(settings, recorded, meta, now),
      updated_at: now
    )
  end

  private

  def summary(settings, recorded, meta, now)
    parts = [ "#{recorded} new #{'outcome'.pluralize(recorded)} recorded." ]
    parts << if settings.meta_configured?
      "Meta: #{meta[:sent]} sent, #{meta[:skipped]} skipped, #{meta[:failed]} failed."
    else
      "Meta: off."
    end
    parts << if settings.google_feed_configured?
      "Google: #{AdConversions::GoogleFeed.rows(now: now).size} in the feed."
    else
      "Google: off."
    end
    parts.join(" ")
  end
end
