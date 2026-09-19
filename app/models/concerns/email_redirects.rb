module EmailRedirects
  extend ActiveSupport::Concern

  REDIRECT_LIMIT = 20

  included do
    serialize :email_redirects, coder: JSON
    after_update :record_email_redirect_on_change
  end

  # Follow a former address to its correction, transitively, using only
  # evidence from actual email edits on this owner (and its people).
  # Unknown addresses (never the owner's) pass through untouched so
  # explicit alternate recipients stay exactly where the captain put them.
  def redirect_map
    raw = email_redirects
    raw = JSON.parse(raw) if raw.is_a?(String)
    Hash(raw).transform_keys { |key| key.to_s.strip.downcase }
  rescue JSON::ParserError
    {}
  end

  def resolve_redirected_email(address)
    normalized = address.to_s.strip.downcase
    return "" if normalized.blank?

    redirects = redirect_map
    return normalized unless redirects.key?(normalized)

    seen = Set.new([ normalized ])
    current = redirects[normalized].to_s.strip.downcase
    while current.present? && redirects.key?(current) && !seen.include?(current) && seen.size <= REDIRECT_LIMIT
      seen << current
      current = redirects[current].to_s.strip.downcase
    end
    current
  end

  def resolve_redirected_list(value)
    parts = value.to_s.split(/[,\n;]/).map(&:strip).reject(&:blank?)
    resolved = parts.map { |part| resolve_redirected_email(part) }.reject(&:blank?).uniq
    # Preserve display order but drop duplicates case-insensitively.
    resolved.uniq { |addr| addr.downcase }
  end

  def resolve_redirected_field(value)
    resolve_redirected_list(value).join(", ")
  end

  def record_email_redirect(old_address, new_address)
    old_key = old_address.to_s.strip.downcase
    return if old_key.blank?

    new_value = new_address.to_s.strip.downcase
    return if old_key == new_value

    redirects = redirect_map
    redirects[old_key] = new_value
    # Bound growth; keep the most recent corrections.
    redirects = redirects.to_a.last(REDIRECT_LIMIT).to_h if redirects.size > REDIRECT_LIMIT
    self.class.unscoped.where(id: id).update_all(email_redirects: redirects.to_json)
    self.email_redirects = redirects
  end

  private

  def record_email_redirect_on_change
    return unless saved_change_to_email?

    old_email, new_email = saved_change_to_email
    record_email_redirect(old_email, new_email)
  end
end
