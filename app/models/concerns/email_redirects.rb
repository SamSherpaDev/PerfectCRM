module EmailRedirects
  extend ActiveSupport::Concern

  included do
    serialize :email_redirects, coder: JSON
    serialize :ambiguous_emails, coder: JSON
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

  def self.mailboxes(value)
    ::Mail::AddressList.new(value.to_s.tr(";\n", ",,")).addresses.map { |address| address.address.to_s.strip.downcase }.compact_blank.uniq
  end

  def resolve_redirected_email(address)
    normalized = EmailRedirects.mailboxes(address).first.to_s
    return "" if normalized.blank?

    redirects = redirect_map
    active = current_recipient_emails | ambiguous_recipient_emails
    seen = Set.new
    current = normalized
    while current.present? && redirects.key?(current) && !active.include?(current) && !seen.include?(current)
      seen << current
      current = redirects[current].to_s.strip.downcase
    end
    current
  end

  def resolve_redirected_list(value)
    parts = EmailRedirects.mailboxes(value)
    resolved = parts.map { |part| resolve_redirected_email(part) }.reject(&:blank?).uniq
    # Preserve display order but drop duplicates case-insensitively.
    resolved.uniq { |addr| addr.downcase }
  end

  def resolve_redirected_field(value)
    resolve_redirected_list(value).join(", ")
  rescue ::Mail::Field::ParseError
    value.to_s
  end

  def record_email_redirect(old_address, new_address)
    old_key = old_address.to_s.strip.downcase
    new_value = new_address.to_s.strip.downcase

    self.class.transaction do
      current = self.class.unscoped.lock.find(id)
      ambiguity = current.ambiguous_recipient_emails
      ambiguity |= [ old_key, new_value ].select { |address| current.redirect_map.key?(address) }
      redirects = current.redirect_map.transform_values { |value| current.resolve_redirected_email(value) }
      redirects[new_value] = new_value if redirects.key?(new_value)
      if old_key.present?
        unless ambiguity.include?(old_key) || current.current_recipient_emails.include?(old_key)
          redirects.transform_values! { |value| value == old_key ? new_value : value }
        end
        redirects.delete(old_key)
        redirects[old_key] = new_value
      end
      ambiguity |= redirects.keys & current.current_recipient_emails
      current.update_columns(email_redirects: redirects, ambiguous_emails: ambiguity)
      self.email_redirects = redirects
      self.ambiguous_emails = ambiguity
    end
  end

  def current_recipient_emails
    ([ email ] + people.pluck(:email)).compact_blank.map { |address| address.strip.downcase }.uniq
  end

  def ambiguous_recipient_emails
    Array(ambiguous_emails) | (redirect_map.keys & current_recipient_emails)
  end

  def recipient_confirmation_token
    Rails.application.message_verifier(:recipient_confirmation).generate(recipient_confirmation_state)
  end

  def recipient_confirmation_valid?(token)
    Rails.application.message_verifier(:recipient_confirmation).verified(token.to_s) == recipient_confirmation_state
  end

  private

  def recipient_confirmation_state
    Digest::SHA256.hexdigest([
      self.class.name, id, email, updated_at, redirect_map.sort, ambiguous_recipient_emails.sort,
      people.reorder(:id).pluck(:id, :email, :updated_at)
    ].to_json)
  end

  def record_email_redirect_on_change
    return unless saved_change_to_email?

    old_email, new_email = saved_change_to_email
    record_email_redirect(old_email, new_email)
  end
end
