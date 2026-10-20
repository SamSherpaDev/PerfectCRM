# Accepts only a relative Today path with a known calendar view and ISO date.
module TodayReturnPath
  extend ActiveSupport::Concern

  private

  def safe_today_return_path(value)
    return unless value.present?

    uri = URI.parse(value)
    return unless uri.relative? && uri.host.nil? && uri.path == root_path

    query = URI.decode_www_form(uri.query.to_s).to_h
    view = query["view"] if %w[week month].include?(query["view"])
    date = Date.iso8601(query["date"]).iso8601 if query["date"].present?
    root_path({ view: view, date: date }.compact)
  rescue URI::InvalidURIError, ArgumentError
    nil
  end
end
