# Accepts only a relative Leads or Clients list path with known tab, query, and sort.
module ListReturnPath
  extend ActiveSupport::Concern

  private

  def safe_leads_return_path(value)
    safe_list_return_path(value, leads_path, LeadsController) { |query| leads_path(query) }
  end

  def safe_clients_return_path(value)
    safe_list_return_path(value, clients_path, ClientsController) { |query| clients_path(query) }
  end

  def safe_list_return_path(value, list_path, list)
    return unless value.present?

    uri = URI.parse(value)
    return unless uri.relative? && uri.host.nil? && uri.path == list_path && uri.fragment.nil?

    pairs = URI.decode_www_form(uri.query.to_s)
    return unless pairs.map(&:first).uniq.length == pairs.length
    return unless (pairs.map(&:first) - %w[tab q sort]).empty?

    query = pairs.to_h
    return if query["tab"].present? && !list::TABS.include?(query["tab"])
    return if query["sort"].present? && !list::SORTS.include?(query["sort"])

    yield query
  rescue URI::InvalidURIError, ArgumentError
    nil
  end
end
