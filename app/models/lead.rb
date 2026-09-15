class Lead < ApplicationRecord
  KINDS = %w[individual company].freeze
  SOURCES = %w[google_ads meta_ads website_form email referral manual].freeze
  STATUSES = %w[new chatting quoted nudged lost].freeze
  # Stages an automation (n8n, Panda AI) may set. Quoted, nudged, and won
  # stay manual; conversion is manual too. Enforced in Leads::Transition.
  AUTOMATION_STATUSES = %w[new chatting lost].freeze
  LOST_REASONS = %w[no_reply price dates chose_another not_a_fit other].freeze
  # A card glows stale after this long with no touch.
  STALE_AFTER = 7.days
  FIT_BANDS = %w[strong possible weak].freeze

  encrypts :phone

  belongs_to :referred_by_organization, class_name: "Organization", optional: true
  belongs_to :converted_client, class_name: "Client", optional: true
  has_many :people, -> { order(:created_at, :id) }, dependent: :destroy, inverse_of: :lead
  has_many :notes, as: :notable, dependent: :destroy
  has_many :tasks, as: :subject, dependent: :destroy
  has_many :taggings, as: :taggable, dependent: :destroy
  has_many :tags, -> { order(:name) }, through: :taggings
  has_many :activity_events, as: :subject, dependent: :destroy

  accepts_nested_attributes_for :people, allow_destroy: true,
    reject_if: proc { |attrs| attrs["name"].blank? && attrs["email"].blank? && attrs["phone"].blank? }

  include TaggedRecord
  include NestedPeople

  before_save :reject_converted_write, prepend: true

  before_validation :normalize_email
  before_validation :normalize_external_ref
  normalizes :lost_reason, with: ->(value) { value.to_s.strip.presence }

  before_validation :normalize_trip_interest
  before_create :stamp_stage
  validate :no_changes_when_converted, on: :update
  validate :no_unconvert, on: :update

  validates :name, presence: true
  validates :kind, inclusion: { in: KINDS }
  validates :source, inclusion: { in: SOURCES }
  validates :status, inclusion: { in: STATUSES }
  validates :email, format: { with: URI::MailTo::EMAIL_REGEXP, allow_blank: true }
  validates :email, :perfectbook_contact_id,
    uniqueness: { allow_nil: true, conditions: -> { open } },
    if: -> { converted_client_id.nil? && status != "lost" }
  validates :external_ref, uniqueness: { allow_nil: true }
  validates :perfectbook_contact_id, numericality: { only_integer: true, greater_than: 0, allow_nil: true }
  validates :fit_score, numericality: { only_integer: true, greater_than_or_equal_to: 0, less_than_or_equal_to: 100, allow_nil: true }
  validates :fit_band, inclusion: { in: FIT_BANDS }, allow_blank: true
  validates :lost_reason, inclusion: { in: LOST_REASONS }, allow_nil: true
  validate :lost_reason_required_when_lost
  validates :expected_value_minor,
    numericality: { only_integer: true, greater_than_or_equal_to: 0, allow_nil: true }

  after_create :stamp_activity
  after_save :sync_fts_later
  after_destroy :remove_fts_row

  scope :open, -> { where(converted_client_id: nil).where.not(status: "lost") }
  scope :lost, -> { where(status: "lost").where(converted_client_id: nil) }
  scope :converted, -> { where.not(converted_client_id: nil) }
  scope :by_status, ->(status) { where(status: status).where(converted_client_id: nil) }
  scope :stale, -> {
    open.where("COALESCE(last_touch_at, last_activity_at, updated_at, created_at) < ?", STALE_AFTER.ago)
  }
  scope :ordered, -> { order(Arel.sql("COALESCE(last_activity_at, updated_at) DESC")) }
  scope :by_name, -> { order(:name) }

  def self.search(query)
    term = query.to_s.strip
    return ordered if term.blank?

    fts_ids = fts_match_ids(term)
    like = "%#{sanitize_sql_like(term.downcase)}%"
    direct_ids = where("lower(name) LIKE ? OR lower(email) LIKE ? OR lower(campaign_name) LIKE ? OR lower(external_ref) LIKE ?",
      like, like, like, like).pluck(:id)
    lead_person_ids = Person.where.not(lead_id: nil)
      .where("lower(email) LIKE ? OR lower(name) LIKE ?", like, like).pluck(:lead_id)
    ids = (fts_ids + direct_ids + lead_person_ids).uniq.compact
    return none if ids.empty?

    where(id: ids).ordered
  end

  def self.fts_match_ids(term)
    fts_query = build_fts_query(term)
    return [] if fts_query.blank?

    ensure_fts!
    rows = connection.select_all(
      sanitize_sql([ "SELECT rowid FROM leads_fts WHERE leads_fts MATCH ?", fts_query ])
    )
    rows.map { |row| row["rowid"] }
  rescue ActiveRecord::StatementInvalid
    []
  end

  def self.build_fts_query(term)
    tokens = term.to_s.scan(/[[:alnum:]]+@?[[:alnum:].\-_]*/).map(&:strip).reject(&:blank?).first(10)
    return nil if tokens.empty?

    tokens.map { |token| "\"#{token.gsub('"', '""')}\"*" }.join(" OR ")
  end

  def self.ensure_fts!
    connection.execute(<<~SQL)
      CREATE VIRTUAL TABLE IF NOT EXISTS leads_fts
      USING fts5(name, email, phone_tail, tags, notes, tokenize='porter unicode61');
    SQL
  end

  def converted?
    converted_client_id.present?
  end

  def readonly_after_convert?
    converted?
  end

  def matching_client
    by_perfectbook = Client.find_by(perfectbook_contact_id: perfectbook_contact_id) if perfectbook_contact_id.present?
    by_perfectbook || (Client.find_by(email: email.to_s.strip.downcase) if email.present?)
  end

  def convert_to_client!(expected_client_id: nil)
    with_lock do
      raise ActiveRecord::RecordInvalid, self if converted?

      client = matching_client
      if expected_client_id && expected_client_id.to_s != (client&.id&.to_s || "new")
        errors.add(:base, "The matching client changed. Review the conversion again.")
        raise ActiveRecord::RecordInvalid, self
      end
      returning = client.present?
      client ||= Client.create!(
        name: name,
        email: email,
        phone: phone,
        country: country,
        state: state,
        kind: kind,
        source: source,
        campaign_name: campaign_name,
        referred_by_organization: referred_by_organization,
        perfectbook_contact_id: perfectbook_contact_id
      )
      client.update!(pipeline_stage: "won")
      people.find_each do |person|
        next if person.email.present? && client.people.exists?(email: person.email)

        client.people.create!(
          name: person.name, email: person.email, phone: person.phone, role: person.role
        )
      end
      client.tags |= tags.to_a
      note_ids = {}
      ActivityEvent.suppress do
        notes.find_each do |note|
          copied_note = Note.create!(notable: client, body: note.body, author: note.author, created_at: note.created_at)
          note_ids[note.id] = copied_note.id
        end
      end
      activity_events.find_each do |event|
        metadata = (event.metadata || {}).merge("from_lead_id" => id)
        metadata["note_id"] = note_ids.fetch(metadata["note_id"]) if note_ids.key?(metadata["note_id"])
        ActivityEvent.create!(
          subject: client, kind: event.kind, summary: event.summary,
          occurred_at: event.occurred_at, metadata: metadata
        )
      end
      tasks.update_all(subject_type: "Client", subject_id: client.id)
      Conversation.where(linkable: self).update_all(linkable_type: "Client", linkable_id: client.id)
      EmailIdentity.where(linkable: self).update_all(linkable_type: "Client", linkable_id: client.id)
      update!(converted_client: client, converted_at: Time.current)
      ActivityEvent.create!(
        subject: self, kind: "conversion", summary: "Converted to client",
        occurred_at: Time.current, metadata: { "client_id" => client.id }
      )
      ActivityEvent.create!(
        subject: client, kind: "conversion",
        summary: returning ? "Returned as a lead from #{source.humanize}" : "Started as a lead",
        occurred_at: Time.current,
        metadata: { "lead_id" => id, "source" => source, "campaign" => campaign_name }
      )
      client.touch_activity!
      client.sync_fts!
      client
    end
  end

  def display_email
    email.presence || people.map(&:email).find(&:present?)
  end

  def touch_activity!
    update_column(:last_activity_at, Time.current) if persisted?
  end

  # The last real contact with the traveler: mail in or out, or a note.
  def record_touch!(at: Time.current)
    return unless persisted?

    self.class.where(id: id).update_all([
      "last_touch_at = MAX(COALESCE(last_touch_at, ?), ?), last_activity_at = MAX(COALESCE(last_activity_at, ?), ?)",
      at, at, at, at
    ])
  end

  def last_touch
    last_touch_at || last_activity_at || updated_at
  end

  def stale?
    return false if converted? || status == "lost"

    (last_touch || Time.current) < STALE_AFTER.ago
  end

  # Whole days spent in the current stage, for the board card.
  def stage_age_days
    base = stage_changed_at || updated_at || Time.current
    ((Time.current - base) / 1.day).floor.clamp(0, 9999)
  end

  def last_activity
    last_activity_at || updated_at
  end

  def fit_label
    [ fit_band.presence&.humanize || "Scoring", fit_score ].compact.join(" · ")
  end

  # Dollars in the form, cents in the column.
  def expected_value_dollars
    expected_value_minor.nil? ? nil : expected_value_minor / 100.0
  end

  def expected_value_dollars=(value)
    text = value.to_s.strip.delete(",$")
    self.expected_value_minor = text.blank? ? nil : (text.to_d * 100).round
  end

  def sync_fts!
    self.class.ensure_fts!
    person_emails = people.reload.map(&:email).compact.join(" ")
    tag_text = tags.reload.order(:name).pluck(:name).join(" ")
    note_text = notes.reload.order(:created_at).pluck(:body).join("\n")
    tails = ([ phone ] + people.map(&:phone)).map { |number| number.to_s.gsub(/\D/, "").last(7).to_s }.reject(&:blank?).uniq.join(" ")
    self.class.connection.execute(
      self.class.sanitize_sql([ "DELETE FROM leads_fts WHERE rowid = ?", id ])
    )
    self.class.connection.execute(
      self.class.sanitize_sql([
        "INSERT INTO leads_fts (rowid, name, email, phone_tail, tags, notes) VALUES (?, ?, ?, ?, ?, ?)",
        id, name.to_s, [ email.to_s, person_emails ].join(" ").strip, tails, tag_text, note_text
      ])
    )
  end

  def remove_fts_row
    self.class.connection.execute(
      self.class.sanitize_sql([ "DELETE FROM leads_fts WHERE rowid = ?", id ])
    )
  rescue ActiveRecord::StatementInvalid
    nil
  end

  private

  def lost_reason_required_when_lost
    return unless status == "lost" && converted_client_id.nil?

    errors.add(:lost_reason, "is required when a lead is lost") if lost_reason.blank?
  end

  def reject_converted_write
    return unless persisted? && self.class.lock.find(id).converted?

    errors.add(:base, "Converted leads stay read-only")
    throw :abort
  end

  def normalize_email
    normalized = email.to_s.strip.downcase
    self.email = normalized.presence
  end

  def normalize_external_ref
    normalized = external_ref.to_s.strip
    self.external_ref = normalized.presence
  end

  def normalize_trip_interest
    normalized = trip_interest.to_s.strip
    self.trip_interest = normalized.presence
  end

  def stamp_stage
    self.stage_changed_at ||= Time.current
    self.last_touch_at ||= Time.current
  end

  # Validate the loaded state for form errors; reject_converted_write checks
  # persisted state under the write lock so a concurrent conversion wins.
  def no_changes_when_converted
    return unless converted_client_id_was.present?
    return if errors.any?

    changed = changes.keys - %w[last_activity_at updated_at]
    if changed.any? || !@pending_tag_list.nil?
      errors.add(:base, "Converted leads stay read-only")
    end
  end

  def no_unconvert
    if converted_client_id_was.present? && converted_client_id.nil?
      errors.add(:converted_client, "cannot be removed once set")
    end
  end

  def stamp_activity
    update_column(:last_activity_at, Time.current)
  end

  def sync_fts_later
    sync_fts!
  rescue ActiveRecord::StatementInvalid
    nil
  end
end
