class Client < ApplicationRecord
  KINDS = %w[individual company].freeze
  SOURCES = %w[website email instagram whatsapp referral repeat other].freeze

  encrypts :phone

  belongs_to :referred_by_organization, class_name: "Organization", optional: true
  has_many :people, -> { order(:created_at, :id) }, dependent: :destroy
  has_many :notes, as: :notable, dependent: :destroy
  has_many :taggings, as: :taggable, dependent: :destroy
  has_many :tags, -> { order(:name) }, through: :taggings
  has_many :activity_events, as: :subject, dependent: :destroy

  accepts_nested_attributes_for :people, allow_destroy: true,
    reject_if: proc { |attrs| attrs["name"].blank? && attrs["email"].blank? && attrs["phone"].blank? }

  include TaggedRecord

  before_validation :normalize_email

  validates :name, presence: true
  validates :kind, inclusion: { in: KINDS }
  validates :source, inclusion: { in: SOURCES }, allow_blank: true
  validates :email, uniqueness: { allow_nil: true },
    format: { with: URI::MailTo::EMAIL_REGEXP, allow_blank: true }
  validates :perfectbook_contact_id, uniqueness: { allow_nil: true },
    numericality: { only_integer: true, greater_than: 0, allow_nil: true }

  after_create :stamp_activity
  after_save :sync_fts_later
  after_destroy :remove_fts_row

  scope :active, -> { where(archived_at: nil) }
  scope :archived, -> { where.not(archived_at: nil) }
  scope :ordered, -> { order(Arel.sql("COALESCE(last_activity_at, updated_at) DESC")) }
  scope :by_name, -> { order(:name) }

  def self.search(query)
    term = query.to_s.strip
    return ordered if term.blank?

    fts_ids = fts_match_ids(term)
    like = "%#{sanitize_sql_like(term.downcase)}%"
    direct_ids = where("lower(name) LIKE ? OR lower(email) LIKE ?", like, like).pluck(:id)
    person_ids = Person.where("lower(email) LIKE ? OR lower(name) LIKE ?", like, like).pluck(:client_id)
    ids = (fts_ids + direct_ids + person_ids).uniq.compact
    return none if ids.empty?

    where(id: ids).ordered
  end

  def self.fts_match_ids(term)
    fts_query = build_fts_query(term)
    return [] if fts_query.blank?

    ensure_fts!
    rows = connection.select_all(
      sanitize_sql([ "SELECT rowid FROM clients_fts WHERE clients_fts MATCH ?", fts_query ])
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
      CREATE VIRTUAL TABLE IF NOT EXISTS clients_fts
      USING fts5(name, email, phone_tail, tags, notes, tokenize='porter unicode61');
    SQL
  end

  def archived?
    archived_at.present?
  end

  def archive!
    update!(archived_at: Time.current)
  end

  def unarchive!
    update!(archived_at: nil)
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

  def sync_fts!
    self.class.ensure_fts!
    person_emails = people.reload.map(&:email).compact.join(" ")
    tag_text = tags.reload.order(:name).pluck(:name).join(" ")
    note_text = notes.reload.order(:created_at).pluck(:body).join("\n")
    tails = ([ phone ] + people.map(&:phone)).map { |number| number.to_s.gsub(/\D/, "").last(7).to_s }.reject(&:blank?).uniq.join(" ")
    self.class.connection.execute(
      self.class.sanitize_sql([ "DELETE FROM clients_fts WHERE rowid = ?", id ])
    )
    self.class.connection.execute(
      self.class.sanitize_sql([
        "INSERT INTO clients_fts (rowid, name, email, phone_tail, tags, notes) VALUES (?, ?, ?, ?, ?, ?)",
        id, name.to_s, [ email.to_s, person_emails ].join(" ").strip, tails, tag_text, note_text
      ])
    )
  end

  def remove_fts_row
    self.class.connection.execute(
      self.class.sanitize_sql([ "DELETE FROM clients_fts WHERE rowid = ?", id ])
    )
  rescue ActiveRecord::StatementInvalid
    nil
  end

  private

  def normalize_email
    normalized = email.to_s.strip.downcase
    self.email = normalized.presence
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
