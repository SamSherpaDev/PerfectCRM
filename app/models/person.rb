class Person < ApplicationRecord
  encrypts :phone

  belongs_to :client, touch: true, optional: true
  belongs_to :lead, touch: true, optional: true

  before_validation :normalize_email
  validate :exactly_one_owner
  validate :email_unique_per_owner

  validates :name, presence: true
  validates :email, format: { with: URI::MailTo::EMAIL_REGEXP, allow_blank: true }

  after_save :refresh_owner_search
  after_destroy :refresh_owner_search

  def owner
    client || lead
  end

  private

  def exactly_one_owner
    has_client = client_id.present? || client.present?
    has_lead = lead_id.present? || lead.present?
    if has_client == has_lead
      errors.add(:base, "Person must belong to a client or a lead")
    end
  end

  # Emails stay matchable for the mail importer: unique within the same
  # client or the same lead, but allowed across different owners so a lead
  # conversion can copy people onto the new client.
  def email_unique_per_owner
    return if email.blank?

    if owner && owner.people.any? { |person| person != self && !person.marked_for_destruction? && person.email.to_s.strip.downcase == email }
      errors.add(:email, "has already been taken")
      return
    end

    excluded_ids = [ id, *owner&.people&.select(&:marked_for_destruction?)&.map(&:id) ].compact

    if client_id.present? || (client.present? && client.persisted?)
      owner_id = client_id.presence || client.id
      if Person.where("lower(email) = ?", email.downcase).where(client_id: owner_id).where.not(id: excluded_ids).exists?
        errors.add(:email, "has already been taken")
      end
    elsif lead_id.present? || (lead.present? && lead.persisted?)
      owner_id = lead_id.presence || lead.id
      if Person.where("lower(email) = ?", email.downcase).where(lead_id: owner_id).where.not(id: excluded_ids).exists?
        errors.add(:email, "has already been taken")
      end
    end
  end

  def normalize_email
    normalized = email.to_s.strip.downcase
    self.email = normalized.presence
  end

  def refresh_owner_search
    if client_id.present?
      fetched = Client.find_by(id: client_id)
      fetched&.touch_activity!
      fetched&.sync_fts!
    elsif lead_id.present?
      fetched = Lead.find_by(id: lead_id)
      fetched&.touch_activity!
      fetched&.sync_fts!
    end
  rescue ActiveRecord::StatementInvalid
    nil
  end
end
