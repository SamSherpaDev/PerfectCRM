require "test_helper"

class AcquisitionTest < ActiveSupport::TestCase
  def snapshot(permission: "allowed", **extra)
    { "acquisition" => { "permission" => { "state" => permission, "measurement" => true, "sharing" => true },
      "first_touch" => { "observed_at" => 1.day.ago.iso8601, "utm_source" => "google", "utm_medium" => "cpc", "gclid" => "example-google",
        "landing_url" => "https://user:password@www.sherpaholidays.com/pages/contact?gclid=example-google&email=example%40example.com&utm_campaign=nepal#secret",
        "referrer" => "https://www.google.com/search?q=private" },
      "last_touch" => { "observed_at" => Time.current.iso8601, "fbclid" => "example-meta", "utm_source" => "facebook", "utm_medium" => "social" } }.deep_merge(extra.stringify_keys) }
  end

  test "snapshots preserve separate evidence and sanitize URLs server side" do
    result = Leads::Acquisition.parse(snapshot)
    assert_equal "google_ads", result.dig("first_touch", "source")
    assert_equal "facebook", result.dig("last_touch", "source")
    assert_equal "example-google", result.dig("first_touch", "gclid")
    assert_nil result.dig("last_touch", "gclid")
    assert_equal "https://www.sherpaholidays.com/pages/contact?utm_campaign=nepal", result.dig("first_touch", "landing_url")
    assert_equal "www.google.com", result.dig("first_touch", "referrer_host")
    assert_equal "crm-source-v1", result["classifier_version"]
  end

  test "denied missing revoked and opted out permission retain no marketing evidence" do
    %w[denied unavailable withdrawn].each do |state|
      result = Leads::Acquisition.parse(snapshot(permission: state))
      assert_equal({ "unknown_reason" => "declined_permission" }, result["first_touch"])
    end
    opted_out = snapshot
    opted_out["acquisition"]["permission"]["opted_out"] = true
    result = Leads::Acquisition.parse(opted_out)
    assert_equal({ "unknown_reason" => "declined_permission" }, result["last_touch"])
    assert_nil Leads::Acquisition.parse({})
    assert_raises(ArgumentError) { Leads::Acquisition.parse({ "acquisition" => {} }) }
  end

  test "direct requires observed time and fbclid alone never means an ad" do
    assert_equal "direct", Leads::Acquisition.touch({ "observed_at" => Time.current.iso8601 }, allowed: true)["source"]
    assert_equal "unknown", Leads::Acquisition.touch({}, allowed: true)["source"]
    assert_equal "facebook", Leads::Acquisition.touch({ "observed_at" => Time.current.iso8601, "fbclid" => "ordinary-link" }, allowed: true)["source"]
    assert_equal "meta_ads", Leads::Acquisition.touch({ "observed_at" => Time.current.iso8601, "fbclid" => "ordinary-link", "utm_source" => "facebook", "utm_medium" => "cpc" }, allowed: true)["source"]
  end

  test "invalid timestamps and overlong IDs fail closed without rejecting legacy payloads" do
    [ "not-a-time", 1.day.from_now.iso8601 ].each do |time|
      assert_raises(ArgumentError) { Leads::Acquisition.touch({ "observed_at" => time }, allowed: true) }
    end
    assert_raises(ArgumentError) { Leads::Acquisition.touch({ "gclid" => "x" * 201 }, allowed: true) }
    assert_equal "legacy-meta", Leads::Acquisition.legacy_attribution({ "landing_url" => "https://www.sherpaholidays.com/?fbclid=legacy-meta" })["fbclid"]
  end
  test "untimed click evidence stays stored but is withheld from attribution" do
    Leads::Acquisition::CLICK_KEYS.each do |key|
      acquisition = Leads::Acquisition.parse({ "acquisition" => {
        "permission" => { "state" => "allowed" }, "last_touch" => { key => "untimed" } } })
      assert_equal "untimed", acquisition.dig("last_touch", key)
      assert_nil Leads::Acquisition.legacy_attribution({}, acquisition: acquisition)[key]
    end
  end

  test "denied submission pages do not retain advertising evidence" do
    acquisition = Leads::Acquisition.parse(snapshot(permission: "denied",
      submission_page: { "url" => "https://example.com", "referrer" => "https://google.com" }))
    assert_nil acquisition["submission_page"]
  end

  test "projection selects a complete eligible snapshot without mixing visits" do
    Leads::Acquisition::CLICK_KEYS.each do |key|
      acquisition = { "permission" => { "state" => "allowed" },
        "last_non_direct_touch" => { "unknown_reason" => "declined_permission" },
        "last_touch" => { "observed_at" => Time.current.iso8601, key => "latest", "utm_campaign" => "latest-campaign" } }
      result = Leads::Acquisition.legacy_attribution({}, acquisition: acquisition)
      assert_equal "latest", result[key]
      assert_equal "latest-campaign", result["utm_campaign"]
      acquisition["last_non_direct_touch"] = { "observed_at" => 1.hour.ago.iso8601, "utm_campaign" => "earlier" }
      result = Leads::Acquisition.legacy_attribution({}, acquisition: acquisition)
      assert_equal "earlier", result["utm_campaign"]
      assert_nil result[key]
    end
  end

end
