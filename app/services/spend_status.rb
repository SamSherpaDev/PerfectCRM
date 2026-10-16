# Receipt times describe successful posts, never the dates money was spent.
# Coverage follows InquiryCosts::Report's campaign IDs, explicit zeros and
# complete currency sets. No amounts are added by this service.
module SpendStatus
  LIMITATION = "Coverage checks campaigns seen in inquiries or spend for the selected period. Campaigns absent from both cannot be detected."

  Receipt = Struct.new(:last_posted_at, :last_changed_at, keyword_init: true) do
    def never_received?
      last_posted_at.nil? && last_changed_at.nil?
    end
  end

  Daily = Struct.new(:source, :start_date, :end_date, :receipt, :received, :required,
    :first_date, :last_date, :through, :stale, :ad_received, :ad_required, keyword_init: true) do
    def missing = required - received
    def complete? = required.positive? && missing.zero?
    def no_completed_days? = end_date < start_date
  end

  Weekly = Struct.new(:source, :week_start, :receipt, :received, :required,
    :latest_week, :missing_campaigns, keyword_init: true) do
    def complete? = received.positive? && missing_campaigns.empty?
  end

  module_function

  def receipt(scope)
    Receipt.new(last_posted_at: scope.maximum(:last_posted_at), last_changed_at: scope.maximum(:updated_at))
  end

  # Additional campaigns are the monthly reader's non-website activity. Its
  # unknown campaigns remain an attribution gap, not an invented spend row.
  def daily(report:, additional_campaigns: [], as_of: Time.current)
    rows = report.campaign_rows
    ads = report.ad_rows
    AdSpend::SOURCES.map do |source|
      entries = rows.select { |row| row.source == source && row.campaign_key }
      campaigns = entries.group_by(&:campaign_key)
      additional_campaigns.select { |row| row.source == source }.each do |row|
        key = report.campaign_key(source: source, id: row.campaign_id, name: row.campaign.presence)
        campaigns[key] ||= [] if key
      end
      complete_dates = campaigns.values.map { |list| list.select(&:spend).map(&:day).max }
      through = complete_dates.min if complete_dates.any? && complete_dates.none?(&:nil?)
      source_ads = ads.select { |row| row.source == source && row.campaign_key && row.ad_id }
      scope = DailyAdSpend.where(source: source)
      selected = scope.campaign_totals.where(spent_on: report.start_date..report.end_date)
      # Historical periods use their own cutoff, so a complete old month
      # does not become stale simply because the report was opened today.
      cutoff = [ as_of.in_time_zone("America/Los_Angeles").to_date, report.end_date + 1 ].min
      Daily.new(source: source, start_date: report.start_date, end_date: report.end_date,
        receipt: receipt(scope), received: entries.count { |row| row.spend },
        required: campaigns.size * ((report.end_date - report.start_date).to_i + 1),
        first_date: selected.minimum(:spent_on), last_date: selected.maximum(:spent_on),
        through: through, stale: complete_dates.compact.any? { |day| day < cutoff - 2 },
        ad_received: source_ads.count { |row| row.spend }, ad_required: source_ads.size)
    end
  end

  def daily_period(start_date:, end_date:, additional_campaigns: [], as_of: Time.current)
    if end_date < start_date
      return AdSpend::SOURCES.map do |source|
        Daily.new(source: source, start_date: start_date, end_date: end_date,
          receipt: receipt(DailyAdSpend.where(source: source)),
          received: 0, required: 0, stale: false, ad_received: 0, ad_required: 0)
      end
    end

    report = InquiryCosts::Report.new(start_date: start_date, end_date: end_date, as_of: end_date + 1)
    daily(report: report, additional_campaigns: additional_campaigns, as_of: as_of)
  end

  def weekly(summary)
    AdSpend::SOURCES.map do |source|
      scope = AdSpend.where(source: source)
      entries = scope.for_week(summary.week_start)
      missing = summary.rows.select do |row|
        row.source == source && row.spend_minor.nil? &&
          (row.inquiries + row.qualified + row.quoted + row.booked).positive?
      end
      Weekly.new(source: source, week_start: summary.week_start, receipt: receipt(scope),
        received: entries.count, required: entries.count + missing.size,
        latest_week: scope.where(week_start: ..summary.week_start).maximum(:week_start), missing_campaigns: missing.map { |row| row.campaign.presence || "Unknown campaign" })
    end
  end
end
