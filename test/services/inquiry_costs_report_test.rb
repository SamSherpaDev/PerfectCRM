require "test_helper"

class InquiryCostsReportTest < ActiveSupport::TestCase
  setup do
    travel_to Time.zone.local(2026, 10, 14, 10)
    @day = Date.new(2026, 10, 13)
  end

  def inquiry(source: "google_ads", campaign_id: "123", campaign: "Nepal", ad_id: "456", **attributes)
    Lead.create!({ name: "Synthetic private person", email: "private@example.test", message: "Private inquiry text",
      source: source, capture_channel: "website_form", received_at: @day.in_time_zone + 10.hours,
      metadata: { "acquisition" => { "permission" => { "state" => "allowed" },
        "last_non_direct_touch" => { "observed_at" => "2026-10-12T20:00:00Z", "source" => source,
          "campaign_id" => campaign_id, "utm_campaign" => campaign, "ad_id" => ad_id } } } }.merge(attributes))
  end

  def spend(day: @day, id: "123", ad_id: "", amount: 1000, currency: "USD", source: "google_ads", name: "Nepal")
    DailyAdSpend.record!(spent_on: day, source: source, campaign_id: id, campaign_name: name,
      currency: currency, amount_minor: amount, ad_id: ad_id, ad_name: ad_id.present? ? "Test ad" : nil)
  end

  def report(start_date: @day, end_date: @day)
    InquiryCosts::Report.new(start_date: start_date, end_date: end_date)
  end

  test "exact daily campaign totals and ads do not double count and renames keep IDs" do
    2.times { inquiry }
    spend(name: "Renamed campaign", amount: 3000)
    spend(ad_id: "456", amount: 2000)
    AdSpend.record!(week_start: @day, source: "google_ads", campaign_name: "Nepal", amount_dollars: "700")
    result = report
    row = result.campaign_rows.sole
    assert_equal [ "Renamed campaign", 2, { "USD" => 3000 }, { "USD" => 1500 } ],
      [ row.campaign, row.inquiries, row.spend, row.cost_per_inquiry ]
    assert_equal({ "USD" => 3000 }, result.daily_rows.find { |item| item.source == "google_ads" }.spend)
    assert_equal({ "USD" => 1000 }, result.ad_rows.sole.cost_per_inquiry)
    assert_equal 2, result.totals[:inquiries]
  end

  test "website eligibility spam tests and historical lifecycle are independent of fit and lost status" do
    spam = inquiry
    spam.tags << Tag.find_or_create_by!(name: Lead::SUSPECTED_SPAM_TAG)
    inquiry(status: "lost", lost_reason: "not_a_fit", fit_band: "weak")
    archived = inquiry
    archived.archive!
    inquiry.convert_to_client!
    inquiry(is_test: true)
    test_client = Client.create!(name: "Synthetic test client", is_test: true)
    inquiry(existing_client: test_client)
    inquiry(capture_channel: "phone")
    Lead.create!(name: "Synthetic manually entered ad lead", source: "google_ads", received_at: @day.in_time_zone)
    result = report
    assert_equal 3, result.totals[:inquiries]
    assert_equal 1, result.totals[:excluded]
    assert_equal [ 3, 1 ], [ result.campaign_rows.sole.inquiries, result.campaign_rows.sole.excluded ]
  end

  test "owner spam stays excluded even if tags are edited and not spam counts it again" do
    lead = inquiry
    lead.mark_as_spam!
    lead.update!(tag_list: "")
    assert_equal [ 0, 1 ], report.totals.values_at(:inquiries, :excluded)
    lead.mark_not_spam!
    assert_equal [ 1, 0 ], report.totals.values_at(:inquiries, :excluded)
  end

  test "Pacific received day including DST and created fallback determines counts" do
    @day = Date.new(2026, 11, 1)
    travel_to Time.zone.local(2026, 11, 3, 10)
    inquiry(received_at: Time.utc(2026, 11, 1, 7))
    inquiry(received_at: Time.utc(2026, 11, 2, 7, 59, 59))
    inquiry(received_at: Time.utc(2026, 11, 2, 8))
    inquiry(received_at: Time.utc(2026, 11, 1, 6, 59, 59))
    inquiry(received_at: nil, created_at: @day.in_time_zone + 12.hours)
    assert_equal 3, report.totals[:inquiries]
  end

  test "legacy website evidence uses exact source or external reference prefix" do
    inquiry(capture_channel: nil, external_ref: "website_form:legacy-one", metadata: {})
    inquiry(capture_channel: nil, external_ref: "websiteXform:not-a-website", metadata: {})
    inquiry(capture_channel: nil, source: "website_form", metadata: {})
    inquiry(capture_channel: "phone", external_ref: "website_form:phone-correction", metadata: {})
    assert_equal 2, report.totals[:inquiries]
  end

  test "missing spend stays unknown while explicit zero is known and no inquiries has no ratio" do
    inquiry
    assert_nil report.campaign_rows.sole.spend
    spend(amount: 0)
    assert_equal({ "USD" => 0 }, report.campaign_rows.sole.cost_per_inquiry)
    spend(id: "empty", amount: 100)
    empty = report.campaign_rows.find { |row| row.campaign_key == "id:empty" }
    assert_equal 0, empty.inquiries
    assert_nil empty.cost_per_inquiry
    spend(ad_id: "456", amount: 50)
    assert_equal({ "USD" => 0 }, report.campaign_rows.find { |row| row.campaign_key == "id:123" }.spend)
  end

  test "missing source campaign or ad makes potentially affected counts and ratios unknown" do
    inquiry
    unassigned = inquiry(campaign_id: nil, campaign: nil, ad_id: nil)
    spend
    spend(ad_id: "456")
    known = report.campaign_rows.find { |row| row.campaign_key == "id:123" }
    assert_equal [ 1, 1 ], [ known.inquiries, known.unassigned ]
    assert_nil known.cost_per_inquiry
    missing = inquiry(source: "website_form", metadata: {})
    result = report
    assert_equal [ 3, 1, 1, 1 ], result.totals.values_at(:inquiries, :unknown_source, :unknown_campaign, :unknown_ad)
    assert_equal 1, result.daily_rows.find { |row| row.source == "google_ads" }.unassigned
    missing.update!(is_test: true)
    unassigned.update!(is_test: true)
    inquiry(ad_id: nil)
    ad = report.ad_rows.find { |row| row.ad_id == "456" }
    assert_equal 1, ad.unassigned
    assert_nil ad.cost_per_inquiry
  end

  test "legacy names join only unique exact source campaign matches and explicit IDs take precedence" do
    legacy = inquiry(campaign_name: "Nepal", metadata: { "attribution" => { "ad_id" => "456" } })
    spend
    assert_equal "id:123", report.campaign_rows.sole.campaign_key
    spend(id: "999")
    unknown = report.campaign_rows.find { |row| row.campaign_key.nil? }
    assert_equal 1, unknown.inquiries
    assert_nil unknown.spend
    assert_equal 1, report.campaign_rows.find { |row| row.campaign_key == "id:123" }.unassigned
    legacy.update!(metadata: { "attribution" => { "campaign_id" => "123", "utm_campaign" => "Old name" } })
    assert_equal 1, report.campaign_rows.find { |row| row.campaign_key == "id:123" }.inquiries
  end

  test "permission and missing snapshots never borrow another touch or compatibility campaign" do
    lead = inquiry
    data = lead.metadata.deep_dup
    data["acquisition"]["permission"]["state"] = "denied"
    lead.update!(metadata: data)
    assert_equal 1, report.totals[:unknown_source]
    data["acquisition"]["permission"]["state"] = "allowed"
    data["acquisition"]["first_touch"] = data["acquisition"].delete("last_non_direct_touch")
    lead.update!(metadata: data)
    assert_equal 1, report.totals[:unknown_source]
    data["acquisition"]["last_non_direct_touch"] = data["acquisition"]["first_touch"].merge("campaign_id" => nil, "utm_campaign" => nil)
    lead.update!(metadata: data, campaign_name: "Legacy name")
    assert_nil report.campaign_rows.sole.campaign_key
  end

  test "falls back to submission_page.landing_url when last_touch is unavailable and permission is allowed" do
    landing_url = "https://www.sherpaholidays.com/pages/everest-base-camp-trek?utm_source=ig&utm_medium=paid&utm_campaign=Nepal+Cold&campaign_id=52666579688338&adset_id=52666579688138&ad_id=52670563689538"
    Lead.create!(
      name: "Synthetic Meta person",
      email: "meta@example.test",
      message: "Everest inquiry",
      source: "website_form",
      capture_channel: "website_form",
      received_at: @day.in_time_zone + 12.hours,
      metadata: {
        "acquisition" => {
          "permission" => { "state" => "allowed", "measurement" => true, "sharing" => true, "observed_at" => "2026-10-13T18:00:00Z" },
          "first_touch" => { "source" => "unknown", "landing_url" => nil, "unknown_reason" => "unavailable" },
          "last_touch" => { "source" => "unknown", "landing_url" => nil, "unknown_reason" => "unavailable" },
          "submission_page" => { "landing_url" => landing_url, "referrer_host" => "instagram.com" }
        }
      }
    )
    spend(source: "meta_ads", id: "52666579688338", name: "Nepal Cold", amount: 2500)
    spend(source: "meta_ads", id: "52666579688338", name: "Nepal Cold", ad_id: "52670563689538", amount: 2500)

    result = report
    assert_equal 0, result.totals[:unknown_source]
    assert_equal 1, result.totals[:inquiries]
    campaign_row = result.campaign_rows.find { |r| r.source == "meta_ads" && r.campaign_key == "id:52666579688338" }
    assert_equal 1, campaign_row.inquiries
    ad_row = result.ad_rows.find { |r| r.source == "meta_ads" && r.ad_id == "52670563689538" }
    assert_equal 1, ad_row.inquiries
    assert_equal({ "USD" => 2500 }, ad_row.cost_per_inquiry)
  end

  test "every selected day and currency requires exact spend and currencies never blend" do
    inquiry
    spend(amount: 101)
    spend(currency: "EUR", amount: 200)
    result = report(start_date: @day - 1)
    previous = result.campaign_rows.find { |row| row.day == @day - 1 }
    assert_nil previous.spend
    assert_equal({ "EUR" => 200, "USD" => 101 }, result.campaign_rows.find { |row| row.day == @day }.spend)
    spend(day: @day - 1, amount: 0)
    assert_nil report(start_date: @day - 1).campaign_rows.find { |row| row.day == @day - 1 }.spend
    spend(day: @day - 1, currency: "EUR", amount: 0)
    assert_equal({ "EUR" => 0, "USD" => 0 }, report(start_date: @day - 1).campaign_rows.find { |row| row.day == @day - 1 }.spend)
  end

  test "ad-only spend never becomes a campaign total or changes monthly campaign costs" do
    inquiry
    spend(ad_id: "456")
    assert_nil report.campaign_rows.sole.spend
    assert_nil report.daily_rows.find { |row| row.source == "google_ads" }.spend
    assert_equal({ "USD" => 1000 }, report.ad_rows.sole.cost_per_inquiry)
    assert_nil WeeklyReport::Monthly.new(month: @day.beginning_of_month, view: "paid").rows.find { |row| row.campaign_id == "123" }.spend
  end

  test "ranges reject partial future old reversed and oversized periods" do
    [ [ @day, Date.current ], [ @day - 31, @day ], [ @day, @day - 1 ], [ Date.current - 2.years - 1, @day ] ].each do |from, to|
      assert_raises(ArgumentError) { report(start_date: from, end_date: to) }
    end
    assert_equal 62, report(start_date: @day - 30).daily_rows.size
  end
end
