require "test_helper"
require_relative "../support/google_sign_in_test_helper"

class ChannelsTest < ActionDispatch::IntegrationTest
  include GoogleSignInTestHelper

  setup do
    travel_to Time.zone.local(2026, 9, 30, 10)
    # The helper builds the signed test identity before this clock jump.
    @claims["exp"] = 1.hour.from_now.to_i
    sign_in
    assert_redirected_to root_path
  end

  test "requires sign in" do
    delete sign_out_path
    get channels_path
    assert_redirected_to sign_in_path
  end

  test "empty page lists all seven channels with honest unknown states and navigation" do
    get channels_path
    assert_response :success
    assert_select "h1", text: "Channels"
    assert_select ".channel-row", count: 7
    ChannelSnapshot::CHANNELS.each_value { |label| assert_select ".channel-name", text: label }
    assert_select ".channel-check-time", text: "No check yet", count: 7
    assert_select ".channel-items", count: 0
    assert_select ".channel-metrics dd", text: "Not attributed", count: 5
    assert_select ".channel-metrics dd", text: "Not checked", count: 14
    assert_select "a.nav-link-active[href=?]", channels_path, text: "Channels"
    assert_select ".tabbar button.on", text: "More"
    assert_includes response.body, "Sep 21-27, Pacific time"
  end

  test "shows the latest check actions reviews and followers while keeping historical checks" do
    ChannelSnapshot.create!(channel: "youtube", checked_at: 2.days.ago, open_items: [], follower_count: 100)
    newest = ChannelSnapshot.create!(channel: "youtube", checked_at: 1.hour.ago,
      open_items: [ "Review new comments", "Review video details" ], review_count: 20,
      review_rating: 4.75, follower_count: 250)
    ChannelSnapshot.create!(channel: "youtube", checked_at: 1.day.ago, open_items: [], follower_count: 150)
    ChannelSnapshot.create!(channel: "tripadvisor", checked_at: 1.hour.ago, open_items: [], review_count: 0)
    get channels_path
    assert_response :success
    assert_select ".channel-row[aria-labelledby=channel-youtube]" do
      assert_select "time[datetime=?]", newest.checked_at.iso8601, text: "Sep 30, 2026 at 09:00 PT"
      assert_select "details summary", text: /2 open items/
      assert_select "details li", text: "Review new comments"
      assert_select "details li", text: "Review video details"
      assert_select "dd", text: "20 (4.75/5)"
      assert_select "dd", text: "250"
    end
    assert_select ".channel-row[aria-labelledby=channel-tripadvisor]" do
      assert_select ".channel-clear", text: "No open items"
      assert_select "dd", text: "0", count: 1
    end
    assert_equal 4, ChannelSnapshot.count
  end

  test "ad metrics aggregate campaigns using the report week and missing spend rules" do
    week = WeeklyReport::Summary.last_complete_week
    at = week.in_time_zone + 2.days
    Lead.create!(name: "Test inquiry", source: "google_ads", campaign_name: "search", received_at: at)
    Lead.create!(name: "Another inquiry", source: "google_ads", campaign_name: "tour", received_at: at)
    Lead.create!(name: "This week", source: "google_ads", campaign_name: "search", received_at: Time.current)
    AdSpend.record!(week_start: week, source: "google_ads", campaign_name: "search", amount_dollars: "100")
    AdSpend.record!(week_start: week, source: "google_ads", campaign_name: "tour", amount_dollars: "50")
    get channels_path
    assert_select ".channel-row[aria-labelledby=channel-google_ads]" do
      assert_select "dd", text: "$150.00"
      assert_select "dd", text: "2"
      assert_select "dd", text: "$75.00"
    end
    Lead.create!(name: "Unfunded campaign", source: "google_ads", campaign_name: "missing", received_at: at)
    get channels_path
    assert_select ".channel-row[aria-labelledby=channel-google_ads]" do
      assert_select "dd", text: "Not available", count: 2
      assert_select "dd", text: "3"
    end
    assert_not_includes response.body, "Unfunded campaign"
    assert_not_includes response.body, "Test inquiry"
  end
end
