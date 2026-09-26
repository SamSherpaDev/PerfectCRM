# Monday 7am Pacific: last week's ads report (README.md, "Weekly ads
# report").
class WeeklyReportJob < ApplicationJob
  queue_as :default

  def perform
    WeeklyReportMailer.weekly.deliver_now
  end
end
