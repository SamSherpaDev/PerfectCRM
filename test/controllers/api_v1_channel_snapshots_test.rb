require "test_helper"

class ApiV1ChannelSnapshotsTest < ActionDispatch::IntegrationTest
  setup do
    @previous_token = ENV["CHANNEL_CHECKS_TOKEN"]
    ENV["CHANNEL_CHECKS_TOKEN"] = "test-only-channel-checks"
    travel_to Time.zone.local(2026, 9, 30, 10)
  end

  teardown do
    ENV["CHANNEL_CHECKS_TOKEN"] = @previous_token
  end

  def payload(**overrides)
    { snapshot: { channel: "youtube", checked_at: Time.current.iso8601,
      open_items: [ "Review new comments" ], review_count: 12, review_rating: 4.75,
      follower_count: 230 }.merge(overrides) }
  end

  def submit(body = payload, authorization: "Bearer test-only-channel-checks", content_type: "application/json")
    post "/api/v1/channels/snapshots", params: body.is_a?(String) ? body : JSON.generate(body),
      headers: { "CONTENT_TYPE" => content_type, "Authorization" => authorization }
  end

  test "disabled endpoint refuses all callers when token is absent or blank" do
    [ nil, "", " " ].each do |value|
      ENV["CHANNEL_CHECKS_TOKEN"] = value
      assert_no_difference "ChannelSnapshot.count" do
        submit
        assert_response :unauthorized
      end
    end
  end

  test "wrong token missing token and missing bearer prefix are refused" do
    [ "Bearer wrong", "", "test-only-channel-checks", "Basic test-only-channel-checks" ].each do |header|
      assert_no_difference "ChannelSnapshot.count" do
        submit authorization: header
        assert_response :unauthorized
      end
    end
  end

  test "stores each check and returns only its aggregate identity" do
    assert_difference "ChannelSnapshot.count", 2 do
      submit
      assert_response :created
      assert_equal %w[channel checked_at id], response.parsed_body.keys.sort
      snapshot = ChannelSnapshot.find(response.parsed_body.fetch("id"))
      assert_equal "youtube", snapshot.channel
      assert_equal Time.current, snapshot.checked_at
      assert_equal [ "Review new comments" ], snapshot.open_items
      assert_equal 12, snapshot.review_count
      assert_equal BigDecimal("4.75"), snapshot.review_rating
      assert_equal 230, snapshot.follower_count
      submit payload(checked_at: 1.hour.ago.iso8601, follower_count: 220)
      assert_response :created
    end
    assert_equal 230, ChannelSnapshot.latest_by_channel.fetch("youtube").follower_count
  end

  test "accepts every fixed channel and unknown metrics without turning them into zeros" do
    ChannelSnapshot::CHANNELS.each_key do |channel|
      submit payload(channel: channel, open_items: [], review_count: nil, review_rating: nil, follower_count: nil)
      assert_response :created
    end
    assert_equal 7, ChannelSnapshot.count
    assert_nil ChannelSnapshot.last.follower_count
    assert_equal 0, ChannelSnapshot.last.open_item_count
  end

  test "rejects invalid values personal text and extra fields without persisting" do
    invalid = [
      { channel: "tiktok" }, { channel: 12 }, { checked_at: "not a time" },
      { checked_at: "2026-09-30T10:00:00" }, { checked_at: 10.minutes.from_now.iso8601 },
      { open_items: nil }, { open_items: "Review new comments" },
      { open_items: [ "x" * 81 ] }, { open_items: [ "Review new comments" ] * 9 },
      { open_items: [ "Review new comments", "Review new comments" ] },
      { open_items: [ "Reply to someone@example.com" ] }, { open_items: [ "Call 415-555-0134" ] },
      { open_items: [ "Review @a_customer" ] }, { open_items: [ "Contact Test Person" ] },
      { review_count: -1 }, { review_count: 1.2 }, { review_count: "12" },
      { follower_count: -1 }, { follower_count: 1_000_000_001 }, { follower_count: true },
      { review_rating: 5.1 }, { review_rating: 0 }, { review_rating: "4.5" },
      { review_count: 0, review_rating: 4.5 }, { email: "someone@example.com" },
      { spend_minor: 2000 }, { inquiries: 10 }
    ]
    invalid.each do |values|
      assert_no_difference "ChannelSnapshot.count" do
        submit payload(**values)
        assert_response :unprocessable_entity, values.inspect
      end
    end
  end

  test "requires snapshot wrapper and mandatory check fields" do
    [ [], {}, { snapshot: [] }, { snapshot: payload[:snapshot], other: 1 },
      { snapshot: payload[:snapshot].except(:open_items) } ].each do |body|
      submit body
      assert_response :unprocessable_entity
    end
    assert_not ChannelSnapshot.exists?
  end

  test "malformed oversized and non JSON bodies fail safely" do
    submit "{"
    assert_response :bad_request
    submit " " * (4 * 1024 + 1)
    assert_response :payload_too_large
    submit "snapshot=test", content_type: "text/plain"
    assert_response :unsupported_media_type
    assert_not ChannelSnapshot.exists?
  end
end
