module SpendStatusHelper
  def spend_period(start_date, end_date)
    if start_date == end_date
      start_date.strftime("%b %-d, %Y")
    elsif start_date.year != end_date.year
      "#{start_date.strftime('%b %-d, %Y')}-#{end_date.strftime('%b %-d, %Y')}"
    elsif start_date.month != end_date.month
      "#{start_date.strftime('%b %-d')}-#{end_date.strftime('%b %-d, %Y')}"
    else
      "#{start_date.strftime('%b %-d')}-#{end_date.strftime('%-d, %Y')}"
    end
  end

  def spend_receipt_line(receipt)
    if receipt.last_posted_at
      "Last posted #{spend_post_time(receipt.last_posted_at)}."
    elsif receipt.last_changed_at
      "Last changed #{spend_post_time(receipt.last_changed_at)}; receipt time unavailable."
    else
      "Never received."
    end
  end

  def daily_spend_status_line(status)
    label = "#{InquiryCosts::Report::SOURCES.fetch(status.source)} daily"
    return "#{label}: no completed days yet. #{spend_receipt_line(status.receipt)}" if status.no_completed_days?

    coverage = if status.receipt.never_received?
      "never received"
    elsif status.complete?
      "complete"
    else
      "incomplete"
    end
    parts = [ "#{label} · #{spend_period(status.start_date, status.end_date)}: #{coverage}." ]
    parts << if status.required.positive?
      "#{status.received} of #{status.required} campaign-days received, #{status.missing} missing."
    else
      "Required campaign-days unknown."
    end
    parts << if status.first_date
      "Spend dates: #{spend_period(status.first_date, status.last_date)}."
    else
      "No spend dates received for this period."
    end
    if status.through
      parts << "Least-current campaign's last day: #{status.through.strftime('%b %-d')}."
    elsif status.required.positive?
      parts << "At least one campaign has no covered day."
    end
    parts << "Stale: over 2 Pacific days behind cutoff." if status.stale
    if status.ad_required.positive?
      parts << "Ad detail: #{status.ad_received} of #{status.ad_required} ad-days received, #{status.ad_required - status.ad_received} missing."
    end
    parts << spend_receipt_line(status.receipt)
    parts.join(" ")
  end

  def weekly_spend_status_line(status)
    label = "#{InquiryCosts::Report::SOURCES.fetch(status.source)} weekly"
    state = if status.receipt.never_received?
      "never received"
    else
      status.complete? ? "complete" : "incomplete"
    end
    parts = [ "#{label} · week of #{spend_period(status.week_start, status.week_start + 6)}: #{state}." ]
    parts << if status.required.positive?
      "#{status.received} of #{status.required} campaign entries received."
    else
      "No campaign entries for this week."
    end
    parts << "Missing campaign entries: #{status.missing_campaigns.join(', ')}." if status.missing_campaigns.any?
    parts << "Latest spend week: #{spend_period(status.latest_week, status.latest_week + 6)}." if status.latest_week
    parts << spend_receipt_line(status.receipt)
    parts.join(" ")
  end

  private

  def spend_post_time(time)
    time.in_time_zone("America/Los_Angeles").strftime("%b %-d, %Y at %H:%M %Z")
  end
end
