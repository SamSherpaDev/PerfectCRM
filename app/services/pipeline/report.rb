# The four numbers a solo operator actually reads, computed live from
# leads and clients. Median first-response time stays nil until the mail
# task lands its inbound/outbound events.
class Pipeline::Report
  def value_by_stage
    sums = Lead.where(converted_client_id: nil).group(:status).sum(:expected_value_minor)
    Lead::STATUSES.index_with { |status| sums.fetch(status, 0).to_i }
  end

  def pipeline_total
    value_by_stage.values.sum
  end

  # First outbound after first inbound per thread; nil until mail lands.
  # Kept as an explicit method so the mail task has one place to fill in.
  def median_first_response_time
    nil
  end

  # Among leads converted this year: share that came back (returning
  # clients) or were referred. Returns { rate:, converted:, repeat:, referral: }.
  def repeat_referral_rate
    year = Time.current.beginning_of_year
    converted = Lead.converted.where("converted_at >= ?", year)
    total = converted.count
    return { rate: nil, converted: 0, repeat: 0, referral: 0 } if total.zero?

    repeat = converted.count { |lead| returning_client?(lead) }
    referral = converted.where(source: "referral").count
    { rate: (repeat + referral).fdiv(total), converted: total, repeat: repeat, referral: referral }
  end

  def inquiries_by_source_this_month
    month = Time.current.beginning_of_month
    Lead.where("created_at >= ?", month).group(:source).count
  end

  # One line for the Monday 7am digest.
  def digest_line
    counts = Lead.where(converted_client_id: nil).group(:status).count
    open = counts.except("lost").values.sum
    stale = Lead.stale.count
    won_month = Lead.converted.where("converted_at >= ?", Time.current.beginning_of_month).count
    "#{open} open, #{stale} stale, #{won_month} won this month, #{helpers_money(pipeline_total)} in the pipeline."
  end

  private

  def returning_client?(lead)
    client = lead.converted_client
    return false if client.nil?

    client.activity_events.where(kind: "conversion")
      .where("summary LIKE ?", "Returned as a lead from %").exists?
  end

  def helpers_money(minor)
    "$#{ActiveSupport::NumberHelper.number_to_delimited(format("%.2f", minor.to_i / 100.0))}"
  end
end
