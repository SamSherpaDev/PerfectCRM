class Person < ApplicationRecord
  include SourceHistory
  belongs_to :origin_person, class_name: "Person", optional: true
  has_many :activity_events, as: :subject, dependent: :destroy
  encrypts :phone

  belongs_to :client, touch: true, optional: true
  belongs_to :lead, touch: true, optional: true

  before_destroy :preserve_linked_source_history, prepend: true

  before_validation :normalize_email
  validate :exactly_one_owner
  validate :email_unique_per_owner

  validates :name, presence: true
  validates :email, format: { with: URI::MailTo::EMAIL_REGEXP, allow_blank: true }

  after_save :refresh_owner_search
  after_destroy :refresh_owner_search
  after_save :record_owner_redirect_on_email_change

  def owner
    client || lead
  end

  def record_owner_redirect_on_email_change
    return unless saved_change_to_email?

    old_email, new_email = saved_change_to_email
    target = client_id.present? ? Client.find_by(id: client_id) : Lead.find_by(id: lead_id)
    target ||= owner
    target&.record_email_redirect(old_email, new_email)
  end

  def linked_source_history?
    persisted? && ([ Lead, Client, Person ].any? { |model| model.where(referred_by_person_id: id).exists? } ||
      Person.where(origin_person_id: id).exists?)
  end

  private

  def preserve_linked_source_history
    return unless linked_source_history?

    errors.add(:base, "Cannot remove a person linked to source history")
    throw :abort
  end

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

    pending_people = owner&.people&.select do |person|
      person.marked_for_destruction? || person.will_save_change_to_email?
    end
    excluded_ids = [ id, *pending_people&.map(&:id) ].compact

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
