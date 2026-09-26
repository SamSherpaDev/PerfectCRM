require "test_helper"
require_relative "../support/google_sign_in_test_helper"

class WeeklyReportSettingsTest < ActionDispatch::IntegrationTest
  include GoogleSignInTestHelper
  include ActionMailer::TestHelper

  setup do
    sign_in
    travel_to Time.zone.local(2026, 9, 22, 9)
  end

  test "settings save the recipient and require campaign spend" do
    get edit_settings_path
    assert_response :success
    assert_select "h2", text: "Monday ads report"
    assert_select "input[name='setting[weekly_report_enabled]']", count: 0
    assert_select "input[name='setting[travelers_goal]']", count: 0
    assert_select "input[name='ad_spend[campaign_name]'][required]"
    assert_select "select[name='ad_spend[week_start]'] option[value='2026-09-14']", text: "Sep 14-20 (last week)"

    patch settings_path, params: { setting: { weekly_report_recipient: " Sam@Example.com " } }
    assert_redirected_to edit_settings_path(anchor: "weekly-report-heading")
    settings = Setting.current.reload
    assert_equal "sam@example.com", settings.weekly_report_to
  end

  test "a bad recipient is shown on the card" do
    patch settings_path, params: { setting: { weekly_report_recipient: "not an email" } }
    assert_response :unprocessable_entity
    assert_select "[role=alert]", text: /Weekly report recipient is invalid/
  end

  test "spend is entered, listed, and removed" do
    post settings_ad_spends_path, params: { ad_spend: { week_start: "2026-09-14", source: "meta_ads", campaign_name: "social", amount_dollars: "140" } }
    assert_redirected_to edit_settings_path(anchor: "weekly-report-heading")
    assert_equal "Saved $140 for Meta social, week of Sep 14-20.", flash[:notice]
    entry = AdSpend.sole

    get edit_settings_path
    assert_select "li", text: /Meta social · \$140/

    delete settings_ad_spend_path(entry)
    assert_not AdSpend.exists?
  end

  test "bad spend comes back as a message" do
    post settings_ad_spends_path, params: { ad_spend: { week_start: "", source: "meta_ads", amount_dollars: "140" } }
    assert_equal "Choose the week the money was spent.", flash[:alert]
    post settings_ad_spends_path, params: { ad_spend: { week_start: "2026-09-14", source: "meta_ads", campaign_name: "social", amount_dollars: "lots" } }
    assert_equal "Enter the amount spent, like 126 or 126.50", flash[:alert]
    assert_not AdSpend.exists?
  end

  test "channel totals are rejected" do
    post settings_ad_spends_path, params: { ad_spend: { week_start: "2026-09-14", source: "meta_ads", campaign_name: "", amount_dollars: "140" } }
    assert_includes flash[:alert], "Campaign name can't be blank"
    assert_not AdSpend.exists?
  end

  test "preview shows any past week and sends on request" do
    get settings_weekly_report_path
    assert_response :success
    assert_select "h1", text: "Monday ads report"
    assert_includes response.body, "SherpaHolidays ads, week of Sep 14-20"

    get settings_weekly_report_path(week: "2026-09-02")
    assert_includes response.body, "SherpaHolidays ads, week of Aug 31-Sep 6"
    get settings_weekly_report_path(week: "2027-01-04")
    assert_includes response.body, "week of Sep 14-20"

    assert_enqueued_emails 1 do
      post deliver_settings_weekly_report_path(week: "2026-09-07")
    end
    assert_redirected_to settings_weekly_report_path(week: "2026-09-07")
  end
end
