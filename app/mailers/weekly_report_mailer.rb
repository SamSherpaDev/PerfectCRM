# The Monday ads report (README.md, "Weekly ads report"): last week's
# inquiries, qualified leads, and bookings by channel and campaign, with
# cost per inquiry where spend is entered. Plain and phone sized.
class WeeklyReportMailer < ApplicationMailer
  default from: "PerfectCRM <info@sherpaholidays.com>"
  helper WeeklyReportHelper

  def weekly(week_start: WeeklyReport::Summary.last_complete_week, to: Setting.current.weekly_report_to)
    @summary = WeeklyReport::Summary.new(week_start: week_start)
    mail(to: to, subject: self.class.subject_for(@summary))
  end

  def self.subject_for(summary)
    "SherpaHolidays ads, #{summary.week_label}: #{summary.headline}"
  end
end
