# The Monday ads report in the app (README.md, "Weekly ads report"): any
# week's email as it would arrive, plus a send-now button.
class WeeklyReportsController < ApplicationController
  def show
    @summary = WeeklyReport::Summary.new(week_start: requested_week)
    @subject = WeeklyReportMailer.subject_for(@summary)
    @recipient = Setting.current.weekly_report_to
    @current_week = Date.current.beginning_of_week(:monday)
  end

  def deliver
    week = requested_week
    recipient = Setting.current.weekly_report_to
    WeeklyReportMailer.weekly(week_start: week, to: recipient).deliver_later
    redirect_to settings_weekly_report_path(week: week.iso8601),
      notice: "Report for #{WeeklyReport::Summary.week_label(week)} sent to #{recipient}.",
      status: :see_other
  end

  private

  # A Monday on or before this week; anything else falls back to last week.
  def requested_week
    week = Date.iso8601(params[:week].to_s).beginning_of_week(:monday)
    week > Date.current ? WeeklyReport::Summary.last_complete_week : week
  rescue Date::Error
    WeeklyReport::Summary.last_complete_week
  end
end
