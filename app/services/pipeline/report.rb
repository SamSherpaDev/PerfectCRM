# Report definitions and deferred metrics: README.md, "Pipeline".
class Pipeline::Report
  def value_by_stage
    sums = Lead.active.where(converted_client_id: nil).group(:status).sum(:expected_value_minor)
    values = Pipeline::Board::STAGES.index_with do |stage|
      Pipeline::Board::LEAD_STAGES.include?(stage) ? { "USD" => sums.fetch(stage, 0).to_i } : {}
    end
    Client.active.includes(:perfectbook_bookings, :converted_leads).each do |client|
      client.pipeline_values_by_currency.each do |currency, minor|
        stage = values.fetch(client.pipeline_stage)
        stage[currency] = stage.fetch(currency, 0) + minor
      end
    end
    values
  end

  def pipeline_total
    Lead.open.sum(:expected_value_minor).to_i
  end

  # Reserved integration point for first-response reporting.
  def median_first_response_time
    nil
  end

  # Among leads converted this year: share that came back (returning
  # clients) or were referred. Returns { rate:, converted:, repeat:, referral: }.
  def repeat_referral_rate
    year = Time.current.beginning_of_year
    converted = Lead.converted.where("converted_at >= ?", year)
    total = converted.count
    return { rate: nil, converted: 0, repeat: 0, referral: 0, qualifying: 0 } if total.zero?

    returning_ids = converted.select { |lead| returning_client?(lead) }.map(&:id)
    repeat = returning_ids.size
    referral = converted.where(source: "referral").count
    qualifying = (returning_ids | converted.where(source: "referral").pluck(:id)).size
    { rate: qualifying.fdiv(total), converted: total, repeat: repeat, referral: referral, qualifying: qualifying }
  end

  def inquiries_by_source_this_month
    month = Time.current.beginning_of_month
    Lead.where("created_at >= ?", month).group(:source).count
  end

  def digest_line
    counts = Lead.active.where(converted_client_id: nil).group(:status).count
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
      .where("summary LIKE ?", "Returned as a lead from %")
      .where("json_extract(metadata, '$.lead_id') = ?", lead.id).exists?
  end

  def helpers_money(minor)
    "$#{ActiveSupport::NumberHelper.number_to_delimited(format("%.2f", minor.to_i / 100.0))}"
  end
end
