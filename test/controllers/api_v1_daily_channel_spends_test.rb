require "test_helper"

class ApiV1DailyChannelSpendsTest < ActionDispatch::IntegrationTest
  setup do
    @old_token = ENV["CHANNEL_CHECKS_TOKEN"]
    ENV["CHANNEL_CHECKS_TOKEN"] = "synthetic-daily-token"
    travel_to Time.zone.local(2026, 10, 14, 10)
  end

  teardown { ENV["CHANNEL_CHECKS_TOKEN"] = @old_token }

  test "identical accepted repost advances receipt time and failed batches leave it unchanged" do
    submit
    assert_response :created
    entry = DailyAdSpend.sole
    assert_equal Time.current, entry.last_posted_at
    original_day = entry.spent_on
    travel 1.hour
    submit
    assert_response :created
    assert_equal Time.current, entry.reload.last_posted_at
    receipt = entry.last_posted_at
    travel 1.hour
    submit [ row(amount_minor: 1000), row(campaign_id: "bad", amount_minor: -1) ]
    assert_response :unprocessable_entity
    assert_equal receipt, entry.reload.last_posted_at
    assert_equal 1500, entry.amount_minor
    assert_equal original_day, entry.spent_on
    submit token: "Bearer wrong"
    assert_response :unauthorized
    assert_equal receipt, entry.reload.last_posted_at
  end

  def row(**attributes)
    { spent_on: "2026-10-13", source: "google_ads", campaign_id: "123", campaign_name: "Nepal",
      currency: "USD", amount_minor: 1500 }.merge(attributes)
  end

  def submit(rows = [ row ], token: "Bearer synthetic-daily-token", body: nil, type: "application/json")
    post "/api/v1/channels/daily_spend", params: body || { spends: rows }.to_json,
      headers: { "Content-Type" => type, "Authorization" => token }
  end

  test "legacy daily shape and optional ad rows replace independent stable identities" do
    submit [ row, row(ad_id: "456", ad_name: "Original ad", amount_minor: 1000), row(ad_id: "789", amount_minor: 500) ]
    assert_response :created
    assert_equal({ "entries" => 3 }, response.parsed_body)
    assert_equal 3, DailyAdSpend.count
    submit [ row(campaign_name: "Renamed", ad_id: "456", ad_name: "Renamed ad", amount_minor: 900) ]
    assert_response :created
    assert_equal 3, DailyAdSpend.count
    assert_equal [ 900, "Renamed ad", "Renamed" ], DailyAdSpend.ads.find_by!(ad_id: "456").attributes.values_at("amount_minor", "ad_name", "campaign_name")
    assert_equal 1500, DailyAdSpend.campaign_totals.sole.amount_minor
    assert_equal 500, DailyAdSpend.ads.find_by!(ad_id: "789").amount_minor
  end

  test "authentication remains required for daily ad rows" do
    [ nil, "", "wrong", "Bearer wrong", "Basic synthetic-daily-token" ].each do |token|
      assert_no_difference "DailyAdSpend.count" do
        submit [ row(ad_id: "456") ], token: token
        assert_response :unauthorized
      end
    end
    ENV["CHANNEL_CHECKS_TOKEN"] = nil
    submit
    assert_response :unauthorized
  end

  test "invalid rows roll back campaign and ad replacements atomically" do
    submit
    invalid = [ row(ad_id: ""), row(ad_id: " "), row(ad_id: nil), row(ad_name: "No ID"), row(ad_id: "x" * 201),
      row(ad_id: "456", ad_name: "x" * 201), row(amount_minor: -1), row(amount_minor: 1.5), row(amount_minor: "100"),
      row(amount_minor: 2**64), row(currency: "usd"), row(source: "youtube"), row(campaign_id: " "),
      row(spent_on: "2026-287"), row(spent_on: "2026-10-14"), row(spent_on: "2026-02-30"),
      row(spent_on: "2024-10-13"), row(extra: true) ]
    invalid.each do |bad|
      assert_no_difference "DailyAdSpend.count" do
        submit [ row(amount_minor: 3000), row(ad_id: "new-ad"), bad ]
        assert_response :unprocessable_entity, bad.inspect
      end
      assert_equal 1500, DailyAdSpend.campaign_totals.sole.amount_minor
    end
  end

  test "body shape size type and JSON failures save nothing" do
    [ [], Array.new(101) { row } ].each do |rows|
      submit rows
      assert_response :unprocessable_entity
    end
    [ "[]", "{}", { spends: [ row ], extra: 1 }.to_json ].each do |body|
      submit body: body
      assert_response :unprocessable_entity
    end
    submit body: "{"
    assert_response :bad_request
    submit body: " " * (64 * 1024 + 1)
    assert_response :payload_too_large
    submit type: "text/plain"
    assert_response :unsupported_media_type
    assert_equal 0, DailyAdSpend.count
  end

  test "daily payload logging filters campaign and ad names" do
    filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
    assert_equal({ "spends" => "[FILTERED]" }, filter.filter({ "spends" => [ row(ad_id: "456", ad_name: "Synthetic ad") ] }))
  end
end
