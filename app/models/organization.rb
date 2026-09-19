class Organization < ApplicationRecord
  KINDS = %w[advisor operator other].freeze

  encrypts :phone

  has_many :referred_clients, class_name: "Client",
    foreign_key: :referred_by_organization_id, dependent: :nullify, inverse_of: :referred_by_organization
  has_many :notes, as: :notable, dependent: :destroy
  has_many :tasks, as: :subject, dependent: :destroy
  has_many :taggings, as: :taggable, dependent: :destroy
  has_many :tags, -> { order(:name) }, through: :taggings
  has_many :activity_events, as: :subject, dependent: :destroy
  has_many :conversations, as: :linkable, dependent: :destroy

  include TaggedRecord
  include EmailRedirects

  before_validation :normalize_email
  before_validation :normalize_website

  validates :name, presence: true
  validates :kind, inclusion: { in: KINDS }
  validates :email, uniqueness: { allow_nil: true },
    format: { with: URI::MailTo::EMAIL_REGEXP, allow_blank: true }
  validates :perfectbook_contact_id, uniqueness: { allow_nil: true },
    numericality: { only_integer: true, greater_than: 0, allow_nil: true }
  validates :website, format: { with: %r{\Ahttps?://\S+\z}, allow_blank: true }

  after_create :stamp_activity
  after_save :sync_fts_later
  after_destroy :remove_fts_row

  scope :ordered, -> { order(Arel.sql("COALESCE(last_activity_at, updated_at) DESC")) }

  def self.search(query)
    term = query.to_s.strip
    return ordered if term.blank?

    fts_ids = fts_match_ids(term)
    like = "%#{sanitize_sql_like(term.downcase)}%"
    email_ids = where("lower(email) LIKE ?", like).pluck(:id)
    name_ids = where("lower(name) LIKE ?", like).pluck(:id)
    ids = (fts_ids + email_ids + name_ids).uniq
    return none if ids.empty?

    where(id: ids).ordered
  end

  def self.fts_match_ids(term)
    fts_query = build_fts_query(term)
    return [] if fts_query.blank?

    ensure_fts!
    rows = connection.select_all(
      sanitize_sql([ "SELECT rowid FROM organizations_fts WHERE organizations_fts MATCH ?", fts_query ])
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
      CREATE VIRTUAL TABLE IF NOT EXISTS organizations_fts
      USING fts5(name, email, phone_tail, tags, notes, tokenize='porter unicode61');
    SQL
  end

  def touch_activity!
    update_column(:last_activity_at, Time.current) if persisted?
  end

  def sync_fts!
    self.class.ensure_fts!
    tag_text = tags.reload.order(:name).pluck(:name).join(" ")
    note_text = notes.reload.order(:created_at).pluck(:body).join("\n")
    tail = phone.to_s.gsub(/\D/, "").last(7).to_s
    self.class.connection.execute(
      self.class.sanitize_sql([ "DELETE FROM organizations_fts WHERE rowid = ?", id ])
    )
    self.class.connection.execute(
      self.class.sanitize_sql([
        "INSERT INTO organizations_fts (rowid, name, email, phone_tail, tags, notes) VALUES (?, ?, ?, ?, ?, ?)",
        id, name.to_s, email.to_s, tail, tag_text, note_text
      ])
    )
  end

  def remove_fts_row
    self.class.connection.execute(
      self.class.sanitize_sql([ "DELETE FROM organizations_fts WHERE rowid = ?", id ])
    )
  rescue ActiveRecord::StatementInvalid
    nil
  end

  private

  def normalize_email
    normalized = email.to_s.strip.downcase
    self.email = normalized.presence
  end

  def normalize_website
    normalized = website.to_s.strip
    self.website = normalized.presence
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
