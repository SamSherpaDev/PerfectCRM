class InquiryCostsController < ApplicationController
  def index
    start_date = parse_date(params[:start_date]) || Date.yesterday - 6
    end_date = parse_date(params[:end_date]) || Date.yesterday
    @report = InquiryCosts::Report.new(start_date: start_date, end_date: end_date)
  rescue Date::Error, ArgumentError
    @error = "Choose up to 31 complete days within the last two years."
    @report = InquiryCosts::Report.new
    render :index, status: :unprocessable_entity
  end

  private

  def parse_date(value)
    return if value.blank?
    raise ArgumentError unless value.is_a?(String) && value.match?(/\A\d{4}-\d{2}-\d{2}\z/)

    Date.iso8601(value)
  end
end
