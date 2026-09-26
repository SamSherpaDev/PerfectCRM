require "test_helper"

class WeeklyReportJobTest < ActiveJob::TestCase
  test "sends the Monday report unless it is turned off" do
    assert_difference -> { ActionMailer::Base.deliveries.size }, 1 do
      WeeklyReportJob.perform_now
    end
    assert_match(/\ASherpaHolidays ads, /, ActionMailer::Base.deliveries.last.subject)

    Setting.current.update!(weekly_report_enabled: false)
    assert_no_difference -> { ActionMailer::Base.deliveries.size } do
      WeeklyReportJob.perform_now
    end
  end

  test "is scheduled for Monday mornings" do
    schedule = YAML.load_file(Rails.root.join("config/recurring.yml")).dig("production", "weekly_report")
    assert_equal({ "class" => "WeeklyReportJob", "schedule" => "every monday at 7am" }, schedule)
  end
end
