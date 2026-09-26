# Monday 7am Pacific: last week's ads report (README.md, "Weekly ads
# report"). Skipped when the captain turns it off on Settings.
class WeeklyReportJob < ApplicationJob
  queue_as :default

  def perform
    return unless Setting.current.weekly_report_enabled?

    WeeklyReportMailer.weekly.deliver_now
  end
end
