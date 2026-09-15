class Lead < ApplicationRecord
  KINDS = %w[individual company].freeze
  SOURCES = %w[google_ads meta_ads website_form email referral manual].freeze
  STATUSES = %w[new chatting quoted nudged lost].freeze
  FIT_BANDS = %w[strong possible weak].freeze

  encrypts :phone

  belongs_to :referred_by_organization, class_name: "Organization", optional: true
  belongs_to :converted_client, class_name: "Client", optional: true
  has_many :people, -> { order(:created_at, :id) }, dependent: :destroy, inverse_of: :lead
  has_many :notes, as: :notable, dependent: :destroy
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
  validate :no_changes_when_converted, on: :update
  validate :no_unconvert, on: :update

  validates :name, presence: true
  validates :kind, inclusion: { in: KINDS }
  validates :source, inclusion: { in: SOURCES }
  validates :status, inclusion: { in: STATUSES }
  validates :email, uniqueness: { allow_nil: true },
    format: { with: URI::MailTo::EMAIL_REGEXP, allow_blank: true }
  validates :external_ref, uniqueness: { allow_nil: true }
  validates :perfectbook_contact_id, uniqueness: { allow_nil: true },
    numericality: { only_integer: true, greater_than: 0, allow_nil: true }
  validates :fit_score, numericality: { only_integer: true, greater_than_or_equal_to: 0, less_than_or_equal_to: 100, allow_nil: true }
  validates :fit_band, inclusion: { in: FIT_BANDS }, allow_blank: true

  after_create :stamp_activity
  after_save :sync_fts_later
  after_destroy :remove_fts_row

  scope :open, -> { where(converted_client_id: nil).where.not(status: "lost") }
  scope :lost, -> { where(status: "lost").where(converted_client_id: nil) }
  scope :converted, -> { where.not(converted_client_id: nil) }
  scope :by_status, ->(status) { where(status: status).where(converted_client_id: nil) }
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

  # One-way, manual conversion. Copies facts, people, tags, notes and
  # activity onto a new Client, links forward, and freezes the lead.
  # Raises when already converted. Never reverses.
  def convert_to_client!
    with_lock do
      raise ActiveRecord::RecordInvalid, self if converted?

      new_client = Client.create!(
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
      people.find_each do |person|
        new_client.people.create!(
          name: person.name, email: person.email, phone: person.phone, role: person.role
        )
      end
      new_client.tag_list = tag_list
      new_client.save! if new_client.tag_list.present?
      note_ids = {}
      ActivityEvent.suppress do
        notes.find_each do |note|
          copied_note = Note.create!(notable: new_client, body: note.body, author: note.author, created_at: note.created_at)
          note_ids[note.id] = copied_note.id
        end
      end
      activity_events.find_each do |event|
        metadata = (event.metadata || {}).merge("from_lead_id" => id)
        metadata["note_id"] = note_ids.fetch(metadata["note_id"]) if note_ids.key?(metadata["note_id"])
        ActivityEvent.create!(
          subject: new_client, kind: event.kind, summary: event.summary,
          occurred_at: event.occurred_at, metadata: metadata
        )
      end
      update!(converted_client: new_client, converted_at: Time.current)
      ActivityEvent.create!(
        subject: self, kind: "conversion", summary: "Converted to client",
        occurred_at: Time.current, metadata: { "client_id" => new_client.id }
      )
      ActivityEvent.create!(
        subject: new_client, kind: "conversion", summary: "Started as a lead",
        occurred_at: Time.current,
        metadata: { "lead_id" => id, "source" => source, "campaign" => campaign_name }
      )
      new_client.touch_activity!
      new_client.sync_fts!
      new_client
    end
  end

  def display_email
    email.presence || people.map(&:email).find(&:present?)
  end

  def touch_activity!
    update_column(:last_activity_at, Time.current) if persisted?
  end

  def last_activity
    last_activity_at || updated_at
  end

  def fit_label
    [ fit_band.presence&.humanize || "Scoring", fit_score ].compact.join(" · ")
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
