require "test_helper"

class PipelineReportTest < ActiveSupport::TestCase
  test "value by stage sums expected values of open leads" do
    Lead.create!(name: "New money", source: "manual", status: "new", expected_value_minor: 100_00)
    Lead.create!(name: "Chat money", source: "manual", status: "chatting", expected_value_minor: 250_00)
    Lead.create!(name: "No value", source: "manual", status: "new")
    converted = Lead.create!(name: "Gone", source: "manual", status: "new", expected_value_minor: 999_00)
    converted.convert_to_client!

    report = Pipeline::Report.new
    values = report.value_by_stage
    assert_equal 100_00, values["new"]
    assert_equal 250_00, values["chatting"]
    assert_equal 0, values["quoted"]
    assert_equal 350_00, report.pipeline_total
  end

  test "median first response is nil until mail lands" do
    assert_nil Pipeline::Report.new.median_first_response_time
  end

  test "repeat and referral rate counts returning and referred conversions" do
    report = Pipeline::Report.new
    assert_nil report.repeat_referral_rate[:rate]

    referrer = Organization.create!(name: "Alpine Friends")
    Lead.create!(name: "Referred", source: "referral", referred_by_organization: referrer).convert_to_client!
    Lead.create!(name: "Cold", source: "google_ads").convert_to_client!

    rate = Pipeline::Report.new.repeat_referral_rate
    assert_equal 2, rate[:converted]
    assert_equal 1, rate[:referral]
    assert_in_delta 0.5, rate[:rate]
  end

  test "returning clients count as repeat" do
    existing = Client.create!(name: "Old Friend", email: "friend@example.com", source: "manual")
    Lead.create!(name: "Old Friend", email: "friend@example.com", source: "manual").convert_to_client!

    rate = Pipeline::Report.new.repeat_referral_rate
    assert_equal 1, rate[:repeat]
    assert_in_delta 1.0, rate[:rate]
  end

  test "inquiries by source counts this month only" do
    Lead.create!(name: "This month", source: "google_ads")
    old = Lead.create!(name: "Last month", source: "google_ads")
    old.update_column(:created_at, 2.months.ago)

    counts = Pipeline::Report.new.inquiries_by_source_this_month
    assert_equal 1, counts["google_ads"]
  end

  test "digest line reads in one breath" do
    Lead.create!(name: "Open ask", source: "manual", expected_value_minor: 500_00)
    line = Pipeline::Report.new.digest_line
    assert_match(/1 open/, line)
    assert_match(/\$500\.00/, line)
  end
end
