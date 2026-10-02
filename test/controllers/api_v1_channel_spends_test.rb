require "test_helper"

class ApiV1ChannelSpendsTest < ActionDispatch::IntegrationTest
  setup do
    @previous_token = ENV["CHANNEL_CHECKS_TOKEN"]
    ENV["CHANNEL_CHECKS_TOKEN"] = "test-only-channel-checks"
    travel_to Time.zone.local(2026, 9, 30, 10)
  end

  teardown do
    ENV["CHANNEL_CHECKS_TOKEN"] = @previous_token
  end

  def campaign(**overrides)
    { campaign_name: "Nepal Search", amount_dollars: "126.50" }.merge(overrides)
  end

  def payload(**overrides)
    { spend: { channel: "google_ads", week_start: "2026-09-21",
      campaigns: [ campaign ] }.merge(overrides) }
  end

  def submit(body = payload, authorization: "Bearer test-only-channel-checks", content_type: "application/json")
    post "/api/v1/channels/spend", params: body.is_a?(String) ? body : JSON.generate(body),
      headers: { "CONTENT_TYPE" => content_type, "Authorization" => authorization }
  end

  test "disabled endpoint refuses callers when token is absent or blank" do
    [ nil, "", " " ].each do |value|
      ENV["CHANNEL_CHECKS_TOKEN"] = value
      assert_no_difference "AdSpend.count" do
        submit
        assert_response :unauthorized
      end
    end
  end

  test "wrong missing and non bearer credentials are refused" do
    [ "Bearer wrong", "", "test-only-channel-checks", "Basic test-only-channel-checks" ].each do |header|
      assert_no_difference "AdSpend.count" do
        submit authorization: header
        assert_response :unauthorized
      end
    end
  end

  test "valid posts persist both channels and return the saved aggregate entries" do
    AdSpend::SOURCES.each do |channel|
      assert_difference "AdSpend.count", 2 do
        submit payload(channel: channel, campaigns: [ campaign(campaign_name: " Nepal Search "),
          campaign(campaign_name: "Nepal Groups", amount_dollars: 0) ])
        assert_response :created
      end
      assert_equal({ "entries" => [
        { "channel" => channel, "week_start" => "2026-09-21", "campaign_name" => "Nepal Search", "amount_dollars" => "126.50" },
        { "channel" => channel, "week_start" => "2026-09-21", "campaign_name" => "Nepal Groups", "amount_dollars" => "0.00" }
      ] }, response.parsed_body)
      assert_equal 12650, AdSpend.find_by!(source: channel, campaign_name: "Nepal Search").amount_minor
      assert_equal 0, AdSpend.find_by!(source: channel, campaign_name: "Nepal Groups").amount_minor
    end
  end

  test "repeat post replaces amounts without duplicates or deleting unmentioned entries" do
    submit payload(campaigns: [ campaign, campaign(campaign_name: "Nepal Groups", amount_dollars: "20") ])
    assert_response :created
    ids = AdSpend.order(:id).pluck(:id)

    assert_no_difference "AdSpend.count" do
      submit payload(campaigns: [ campaign(amount_dollars: "42.25") ])
      assert_response :created
    end
    assert_equal ids, AdSpend.order(:id).pluck(:id)
    assert_equal 4225, AdSpend.find_by!(campaign_name: "Nepal Search").amount_minor
    assert_equal 2000, AdSpend.find_by!(campaign_name: "Nepal Groups").amount_minor
    assert_equal "42.25", response.parsed_body.fetch("entries").sole.fetch("amount_dollars")

    submit payload(campaigns: [ campaign(campaign_name: "nepal search", amount_dollars: "10") ])
    assert_response :created
    assert_equal 3, AdSpend.count
  end

  test "duplicate campaigns return only their final saved amount" do
    assert_difference "AdSpend.count", 1 do
      submit payload(campaigns: [ campaign, campaign(campaign_name: " Nepal Search ", amount_dollars: "42.25") ])
      assert_response :created
    end
    assert_equal "42.25", response.parsed_body.fetch("entries").sole.fetch("amount_dollars")
    assert_equal 4225, AdSpend.sole.amount_minor
  end

  test "amounts are returned exactly and out of storage range rolls back the request" do
    submit payload(campaigns: [ campaign(amount_dollars: "90071992547409.93") ])
    assert_response :created
    assert_equal "90071992547409.93", response.parsed_body.fetch("entries").sole.fetch("amount_dollars")

    assert_no_difference "AdSpend.count" do
      submit payload(campaigns: [ campaign(amount_dollars: "30"),
        campaign(campaign_name: "Nepal Groups", amount_dollars: "9999999999999999999999999") ])
      assert_response :unprocessable_entity
    end
    assert_equal 9007199254740993, AdSpend.sole.amount_minor
  end

  test "campaign validation failure rolls back new entries and replacements" do
    existing = AdSpend.record!(week_start: Date.new(2026, 9, 21), source: "google_ads",
      campaign_name: "Nepal Search", amount_dollars: "12")
    [ "", " ", "x" * 161 ].each do |name|
      assert_no_difference "AdSpend.count" do
        submit payload(campaigns: [ campaign(amount_dollars: "30"),
          campaign(campaign_name: "Nepal Groups", amount_dollars: "20"), campaign(campaign_name: name) ])
        assert_response :unprocessable_entity
      end
      assert_equal 1200, existing.reload.amount_minor
      assert_equal %w[error fields], response.parsed_body.keys.sort
      assert_equal "invalid_spend", response.parsed_body.fetch("error")
    end
  end

  test "accepts only Mondays in the last eight complete Pacific weeks" do
    # UTC is already Monday, but the Pacific week is still in progress.
    travel_to Time.utc(2026, 9, 28, 6, 59)
    [ "2026-09-14", "2026-07-27" ].each do |week|
      submit payload(week_start: week)
      assert_response :created
    end
    [ "2026-09-21", "2026-09-28", "2026-07-20", "2026-09-15",
      "2026-02-30", "not a date", "2026-257", nil, 20260914 ].each do |week|
      assert_no_difference "AdSpend.count" do
        submit payload(week_start: week)
        assert_response :unprocessable_entity, week.inspect
      end
    end
    travel_to Time.utc(2026, 9, 28, 7)
    submit payload(week_start: "2026-09-21")
    assert_response :created
    submit payload(week_start: "2026-07-27")
    assert_response :unprocessable_entity
  end

  test "invalid fields shapes channels and amounts save nothing" do
    invalid = [ [], {}, { spend: [] }, { spend: payload[:spend], extra: 1 },
      { spend: payload[:spend].except(:channel) }, { spend: payload[:spend].except(:week_start) },
      { spend: payload[:spend].except(:campaigns) }, payload(channel: "youtube"), payload(channel: "tiktok"), payload(channel: nil),
      payload(channel: 1), payload(extra: 1), payload(campaigns: []), payload(campaigns: nil),
      payload(campaigns: {}), payload(campaigns: [ nil ]),
      payload(campaigns: [ campaign.except(:campaign_name) ]),
      payload(campaigns: [ campaign.except(:amount_dollars) ]),
      payload(campaigns: [ campaign(extra: 1) ]), payload(campaigns: [ campaign(campaign_name: 12) ]) ]
    [ -1, "-0.01", "1.234", 1.234, "", nil, true, {}, [], "$12", "1,200", " 12 ", "NaN" ].each do |amount|
      invalid << payload(campaigns: [ campaign, campaign(campaign_name: "Nepal Groups", amount_dollars: amount) ])
    end
    invalid.each do |body|
      assert_no_difference "AdSpend.count" do
        submit body
        assert_response :unprocessable_entity, body.inspect
        assert_equal "invalid_spend", response.parsed_body.fetch("error")
      end
    end
  end

  test "malformed oversized and non JSON requests fail without saving" do
    submit "{"
    assert_response :bad_request
    submit " " * (16 * 1024 + 1)
    assert_response :payload_too_large
    submit "spend=test", content_type: "text/plain"
    assert_response :unsupported_media_type
    assert_not AdSpend.exists?
  end

  test "weekly summary uses posted spend through the existing computation" do
    submit
    assert_response :created
    submit payload(channel: "meta_ads", campaigns: [ campaign(campaign_name: "Nepal Social", amount_dollars: "20.25") ])
    assert_response :created

    summary = WeeklyReport::Summary.new
    assert_equal Date.new(2026, 9, 21), summary.week_start
    assert_equal 12650, summary.channel_total("google_ads").spend_minor
    assert_equal 2025, summary.channel_total("meta_ads").spend_minor
    assert_equal 14675, summary.paid_total.spend_minor
    assert summary.spend_entered?
    assert_nil summary.channel_total("google_ads").cost_per_inquiry
  end

  test "parameter logging hides the whole spend payload" do
    filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
    assert_equal "[FILTERED]", filter.filter(payload.deep_stringify_keys).fetch("spend")
  end
end
