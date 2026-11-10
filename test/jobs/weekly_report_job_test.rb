require "test_helper"

class WeeklyReportJobTest < ActiveJob::TestCase
  test "always sends the Monday report" do
    assert_difference -> { ActionMailer::Base.deliveries.size }, 1 do
      WeeklyReportJob.perform_now
    end
    assert_match(/\ASherpaHolidays ads, /, ActionMailer::Base.deliveries.last.subject)
  end

  test "is scheduled for Monday mornings" do
    schedule = YAML.load_file(Rails.root.join("config/recurring.yml")).dig("production", "weekly_report")
    assert_equal({ "class" => "WeeklyReportJob", "schedule" => "every monday at 7am America/Los_Angeles" }, schedule)
  end

  test "every clock-time schedule in config/recurring.yml pins America/Los_Angeles" do
    require "fugit"
    schedules = YAML.load_file(Rails.root.join("config/recurring.yml")).fetch("production")
    clock_time = schedules.select { |_, entry| Fugit.parse(entry.fetch("schedule")).hours.present? }
    assert_operator clock_time.size, :>=, 8
    clock_time.each do |name, entry|
      parsed = Fugit.parse(entry.fetch("schedule"))
      assert_equal "America/Los_Angeles", parsed.zone, "#{name} (#{entry["schedule"]}) must specify America/Los_Angeles"
    end
  end
end
