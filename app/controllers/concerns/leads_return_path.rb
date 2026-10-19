# Accepts only a relative Leads list path with known tab, query, and sort.
module LeadsReturnPath
  extend ActiveSupport::Concern

  private

  def safe_leads_return_path(value)
    return unless value.present?

    uri = URI.parse(value)
    return unless uri.relative? && uri.host.nil? && uri.path == leads_path && uri.fragment.nil?

    pairs = URI.decode_www_form(uri.query.to_s)
    return unless pairs.map(&:first).uniq.length == pairs.length
    return unless (pairs.map(&:first) - %w[tab q sort]).empty?

    query = pairs.to_h
    return if query["tab"].present? && !LeadsController::TABS.include?(query["tab"])
    return if query["sort"].present? && !LeadsController::SORTS.include?(query["sort"])

    leads_path(query)
  rescue URI::InvalidURIError, ArgumentError
    nil
  end
end
