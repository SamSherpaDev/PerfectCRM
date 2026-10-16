require "test_helper"

class SpendStatusTest < ActiveSupport::TestCase
  include SpendStatusHelper

  setup { travel_to Time.zone.local(2026, 10, 15, 10) }

  def spend(day: Date.new(2026, 10, 14), source: "google_ads", id: "123", name: "Nepal", currency: "USD", amount: 0, ad_id: "")
    DailyAdSpend.record!(spent_on: day, source: source, campaign_id: id, campaign_name: name,
      currency: currency, amount_minor: amount, ad_id: ad_id)
  end

  def statuses(from: Date.new(2026, 10, 1), through: Date.new(2026, 10, 14))
    SpendStatus.daily_period(start_date: from, end_date: through)
  end

  test "observed partial October has 36 of 84 required campaign days and monthly agrees" do
    AdSpend::SOURCES.each_with_index do |source, index|
      (1..(index.zero? ? 4 : 2)).each do |id|
        (9..14).each { |day| spend(day: Date.new(2026, 10, day), source: source, id: id.to_s) }
      end
    end
    daily = statuses
    assert_equal [ [ 24, 56, 32 ], [ 12, 28, 16 ] ], daily.map { |row| [ row.received, row.required, row.missing ] }
    assert_equal 36, daily.sum(&:received)
    assert_equal 84, daily.sum(&:required)
    assert daily.none?(&:complete?)
    assert daily.none?(&:stale)
    assert_equal [ Date.new(2026, 10, 14) ], daily.map(&:through).uniq
    monthly = WeeklyReport::Monthly.new(view: "paid")
    assert_equal daily.map(&:missing), monthly.spend_statuses.map(&:missing)
    assert monthly.source_rows.all? { |row| row.spend.nil? }
  end

  test "never received differs from legacy rows with an honest change time fallback" do
    missing = statuses.first
    assert missing.receipt.never_received?
    assert_not missing.complete?
    assert_includes daily_spend_status_line(missing), "never received"
    row = DailyAdSpend.create!(spent_on: Date.new(2026, 10, 14), source: "google_ads",
      campaign_id: "123", campaign_name: "Nepal", currency: "USD", amount_minor: 0)
    legacy = statuses.first
    assert_nil row.last_posted_at
    assert_not legacy.receipt.never_received?
    assert_includes daily_spend_status_line(legacy), "Last changed Oct 15, 2026 at 10:00 PDT; receipt time unavailable"
    assert_not_includes daily_spend_status_line(legacy), "Last posted"
  end

  test "explicit zeros count but a missing middle day never becomes zero" do
    [ 12, 14 ].each { |day| spend(day: Date.new(2026, 10, day)) }
    result = statuses(from: Date.new(2026, 10, 12)).first
    assert_equal [ 2, 3, 1 ], [ result.received, result.required, result.missing ]
    assert_equal Date.new(2026, 10, 14), result.through
    assert_not result.complete?
    spend(day: Date.new(2026, 10, 13))
    assert statuses(from: Date.new(2026, 10, 12)).first.complete?
  end

  test "campaign IDs survive renames and ad detail and weekly spend never fill campaign totals" do
    spend(day: Date.new(2026, 10, 13), name: "Original")
    spend(name: "Renamed")
    spend(day: Date.new(2026, 10, 13), id: "only-ad", ad_id: "ad-1", amount: 999_999)
    AdSpend.record!(week_start: Date.new(2026, 10, 12), source: "google_ads", campaign_name: "Renamed", amount_dollars: "9999")
    result = statuses(from: Date.new(2026, 10, 13)).first
    assert_equal [ 2, 4, 2 ], [ result.received, result.required, result.missing ]
    assert_equal [ 1, 2 ], [ result.ad_received, result.ad_required ]
    assert_not result.complete?
    assert_nil result.through
  end

  test "currency coverage uses complete sets without summing currencies or counting them as extra campaign days" do
    spend(day: Date.new(2026, 10, 13), amount: 100)
    spend(amount: 200)
    spend(currency: "EUR", amount: 300)
    result = statuses(from: Date.new(2026, 10, 13)).first
    assert_equal [ 1, 2, 1 ], [ result.received, result.required, result.missing ]
    spend(day: Date.new(2026, 10, 13), currency: "EUR", amount: 400)
    assert statuses(from: Date.new(2026, 10, 13)).first.complete?
    report = InquiryCosts::Report.new(start_date: Date.new(2026, 10, 13), end_date: Date.new(2026, 10, 14))
    assert_equal [ { "USD" => 200, "EUR" => 300 }, { "USD" => 100, "EUR" => 400 } ],
      report.daily_rows.select { |row| row.source == "google_ads" }.map(&:spend)
  end

  test "least current campaign controls freshness and a new backfill receipt cannot disguise its spend date" do
    spend(day: Date.new(2026, 10, 14), id: "fresh")
    old = spend(day: Date.new(2026, 10, 11), id: "behind")
    result = statuses.first
    assert_equal Date.new(2026, 10, 11), result.through
    assert result.stale
    assert_equal Time.current, result.receipt.last_posted_at
    assert_equal Date.new(2026, 10, 11), old.spent_on
  end

  test "more than two days uses Pacific calendar boundaries and historical cutoffs" do
    spend(day: Date.new(2026, 10, 13))
    travel_to Time.utc(2026, 10, 16, 6, 59, 59)
    before = statuses(through: Date.yesterday).first
    assert_equal Date.new(2026, 10, 15), Date.current
    assert_not before.stale
    assert_not before.complete?
    travel_to Time.utc(2026, 10, 16, 7)
    after = statuses(through: Date.yesterday).first
    assert_equal Date.new(2026, 10, 16), Date.current
    assert after.stale
    # Reopening an older cutoff does not age its spend dates.
    assert_not statuses(through: Date.new(2026, 10, 13)).first.stale
  end

  test "fresh complete spend does not resolve attribution" do
    spend(amount: 1000)
    Lead.create!(name: "Synthetic unknown", capture_channel: "website_form", source: "website_form",
      received_at: Date.new(2026, 10, 14).in_time_zone + 10.hours)
    report = InquiryCosts::Report.new(start_date: Date.new(2026, 10, 14), end_date: Date.new(2026, 10, 14))
    assert report.spend_statuses.first.complete?
    assert_nil report.campaign_rows.sole.cost_per_inquiry
    assert_equal 1, report.totals[:unknown_source]
  end

  test "weekly status keeps its own post history and gaps when daily data is fresh" do
    AdSpend.create!(week_start: Date.new(2026, 9, 28), source: "google_ads", campaign_name: "Nepal", amount_minor: 1234)
    spend
    summary = WeeklyReport::Summary.new
    status = summary.spend_statuses.first
    assert_not status.complete?
    assert_equal Date.new(2026, 9, 28), status.latest_week
    assert_includes weekly_spend_status_line(status), "receipt time unavailable"
    assert_nil summary.channel_total("google_ads").spend_minor
    assert_equal 0, summary.total.inquiries
  end

  test "first day of month has no completed daily period" do
    travel_to Time.zone.local(2026, 11, 1, 0, 1)
    result = statuses(from: Date.current, through: Date.yesterday).first
    assert result.no_completed_days?
    assert_includes daily_spend_status_line(result), "no completed days yet"
  end

  test "a complete historical month stays complete after a new backfill post" do
    (Date.new(2026, 9, 1)..Date.new(2026, 9, 30)).each { |day| spend(day: day) }
    result = statuses(from: Date.new(2026, 9, 1), through: Date.new(2026, 9, 30)).first
    assert result.complete?
    assert_not result.stale
    assert_equal [ 30, 30, 0 ], [ result.received, result.required, result.missing ]
    assert_equal Time.current, result.receipt.last_posted_at
    assert_equal Date.new(2026, 9, 30), result.through
  end

  test "monthly activity outside website inquiries also requires campaign spend" do
    spend
    Lead.create!(name: "Synthetic phone inquiry", source: "google_ads", capture_channel: "phone",
      received_at: Date.new(2026, 10, 14).in_time_zone,
      metadata: { "acquisition" => { "last_non_direct_touch" => {
        "observed_at" => "2026-10-12T20:00:00Z", "source" => "google_ads", "campaign_id" => "missing",
        "utm_campaign" => "Missing phone campaign" } } })
    result = WeeklyReport::Monthly.new(view: "paid").spend_statuses.first
    assert_equal [ 1, 28, 27 ], [ result.received, result.required, result.missing ]
    assert_not result.complete?
    assert_nil result.through
  end
end
