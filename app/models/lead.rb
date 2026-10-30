class Lead < ApplicationRecord
  KINDS = %w[individual company].freeze
  SOURCES = %w[google_ads meta_ads trade_show website_form email referral manual].freeze
  STATUSES = %w[new chatting quoted nudged lost].freeze
  # Stages an automation (n8n, Panda AI) may set. Quoted, nudged, and won
  # stay manual; conversion is manual too. Enforced in Leads::Transition.
  AUTOMATION_STATUSES = %w[new chatting lost].freeze
  LOST_REASONS = %w[no_reply price dates chose_another not_a_fit other].freeze
  # A card glows stale after this long with no touch.
  STALE_AFTER = 7.days
  FIT_BANDS = %w[strong possible weak].freeze
  BUDGET_BANDS = %w[discuss under_2000 2000_4000 4000_7000 7000_plus].freeze
  PLACEMENTS = %w[contact landing trip_page].freeze
  SUSPECTED_SPAM_TAG = "suspected_spam"

  encrypts :phone, :phone_raw

  serialize :metadata, coder: JSON

  belongs_to :referred_by_organization, class_name: "Organization", optional: true
  belongs_to :converted_client, class_name: "Client", optional: true
  has_many :people, -> { order(:created_at, :id) }, dependent: :destroy, inverse_of: :lead
  has_many :notes, as: :notable, dependent: :destroy
  has_many :tasks, as: :subject, dependent: :destroy
  has_many :taggings, as: :taggable, dependent: :destroy
  has_many :tags, -> { order(:name) }, through: :taggings
  has_many :lead_notifications, dependent: :destroy
  has_many :activity_events, as: :subject, dependent: :destroy
  has_many :conversations, as: :linkable, dependent: :destroy
  has_many :ad_conversions, dependent: :destroy
  has_many :scheduled_calls, -> { order(:scheduled_at, :id) }, dependent: :destroy, inverse_of: :lead

  accepts_nested_attributes_for :people, allow_destroy: true,
    reject_if: proc { |attrs| attrs["name"].blank? && attrs["email"].blank? && attrs["phone"].blank? }

  include SourceHistory
  belongs_to :existing_client, class_name: "Client", optional: true

  include TaggedRecord
  include NestedPeople
  include ReferralCode
  include EmailRedirects
  include ScheduledCallOwner

  attr_accessor :allow_converted_name_sync, :skip_name_propagation

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
  validate :existing_client_link_valid
  validates :status, inclusion: { in: STATUSES }
  validates :email, format: { with: URI::MailTo::EMAIL_REGEXP, allow_blank: true }
  # Email is not an inquiry identity: repeat visitors can ask about different trips.
  validates :perfectbook_contact_id,
    uniqueness: { allow_nil: true, conditions: -> { open } },
    if: -> { converted_client_id.nil? && status != "lost" && archived_at.nil? }
  validates :external_ref, uniqueness: { allow_nil: true }
  validates :perfectbook_contact_id, numericality: { only_integer: true, greater_than: 0, allow_nil: true }
  validates :fit_score, numericality: { only_integer: true, greater_than_or_equal_to: 0, less_than_or_equal_to: 100, allow_nil: true }
  validates :fit_band, inclusion: { in: FIT_BANDS }, allow_blank: true
  validates :owner_fit_at_inquiry, inclusion: { in: FIT_BANDS }, allow_blank: true
  before_save :stamp_inquiry_review_fit
  after_save :audit_inquiry_review_fit
  validates :lost_reason, inclusion: { in: LOST_REASONS }, allow_nil: true
  validate :lost_reason_required_when_lost
  validates :expected_value_minor,
    numericality: { only_integer: true, greater_than_or_equal_to: 0, allow_nil: true }
  validates :budget_band, inclusion: { in: BUDGET_BANDS }, allow_blank: true
  validates :placement, inclusion: { in: PLACEMENTS }, allow_blank: true
  validates :spam_score, numericality: { only_integer: true, greater_than_or_equal_to: 0, less_than_or_equal_to: 100 }
  validates :travel_month, numericality: { only_integer: true, greater_than_or_equal_to: 1, less_than_or_equal_to: 12, allow_nil: true }
  validates :travel_year, numericality: { only_integer: true, greater_than_or_equal_to: 2020, less_than_or_equal_to: 2100, allow_nil: true }
  validates :party_size, numericality: { only_integer: true, greater_than_or_equal_to: 1, less_than_or_equal_to: 20, allow_nil: true }
  validates :reference, uniqueness: { allow_nil: true }

  after_create :stamp_activity
  after_create :assign_reference
  after_save :sync_fts_later
  after_update :propagate_name_change
  after_destroy :remove_fts_row

  scope :active, -> { where(archived_at: nil) }
  scope :archived, -> { where.not(archived_at: nil) }
  scope :spam, -> {
    flagged = Tagging.joins(:tag).where(taggable_type: "Lead", tags: { name: SUSPECTED_SPAM_TAG }).select(:taggable_id)
    where.not(spam_marked_at: nil).or(where(id: flagged))
  }
  scope :potential, -> { active.where(converted_client_id: nil, not_interested_marked_at: nil).where.not(potential_marked_at: nil).where.not(id: spam.select(:id)) }
  # Unsure holds leads the captain cannot call yet (voicemail, no reply):
  # not clearly Potential, not clearly spam. Suspected spam may wait here.
  scope :unsure, -> { active.where(converted_client_id: nil, spam_marked_at: nil, not_interested_marked_at: nil).where.not(unsure_marked_at: nil) }
  # Not interested sets a lead aside from every call/email list and automation
  # while keeping its stage and Potential/Unsure marks intact for undo.
  scope :not_interested, -> { active.where(converted_client_id: nil, spam_marked_at: nil).where.not(not_interested_marked_at: nil) }
  scope :open, -> { active.where(converted_client_id: nil).where.not(status: "lost") }
  scope :lost, -> { active.where(status: "lost").where(converted_client_id: nil) }
  scope :converted, -> { where.not(converted_client_id: nil) }
  scope :by_status, ->(status) { active.where(status: status).where(converted_client_id: nil) }
  scope :in_new_tab, -> { by_status(%w[new chatting nudged]).where(not_interested_marked_at: nil).where.not(id: potential.select(:id)).where.not(id: unsure.select(:id)) }
  scope :stale, -> {
    open.where(not_interested_marked_at: nil).where("COALESCE(last_touch_at, last_activity_at, updated_at, created_at) < ?", STALE_AFTER.ago)
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

  def self.build_reference(id)
    crc = Zlib.crc32(id.to_s)
    alphabet = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"
    code = +""
    4.times { code.prepend(alphabet[crc % alphabet.length]); crc /= alphabet.length }
    "SH-#{code}"
  end

  def suspected_spam?
    spam_marked_at.present? || tags.any? { |tag| tag.name == SUSPECTED_SPAM_TAG }
  end

  def suspicion_hits
    return [] unless metadata.is_a?(Hash)

    Array(metadata["suspicion_hits"]).map(&:to_s).reject(&:blank?)
  end

  def spam_reason
    ::Leads.spam_reason(suspicion_hits)
  end

  def safety_net_inquiry?
    metadata.is_a?(Hash) && metadata["inquiry_safety_net"] == true
  end

  def potential?
    potential_marked_at.present? && !not_interested? && !archived? && !converted? && !suspected_spam?
  end

  def mark_potential!
    with_lock do
      if archived? || converted? || suspected_spam?
        errors.add(:base, "Only active, non-spam leads can be marked Potential")
        raise ActiveRecord::RecordInvalid, self
      end
      update!(potential_marked_at: potential_marked_at || Time.current, unsure_marked_at: nil, not_interested_marked_at: nil)
      record_interested_again! if saved_change_to_not_interested_marked_at?
    end
    enqueue_ad_conversion
  end

  def unmark_potential!
    with_lock do
      if archived? || converted?
        errors.add(:base, "Only active leads can be changed")
        raise ActiveRecord::RecordInvalid, self
      end
      update!(potential_marked_at: nil)
    end
  end

  def unsure?
    unsure_marked_at.present? && !not_interested? && spam_marked_at.nil? && !archived? && !converted?
  end

  def mark_unsure!
    with_lock do
      if archived? || converted? || spam_marked_at.present?
        errors.add(:base, "Only active leads not marked as spam can be marked Unsure")
        raise ActiveRecord::RecordInvalid, self
      end
      update!(unsure_marked_at: unsure_marked_at || Time.current, potential_marked_at: nil, not_interested_marked_at: nil)
      record_interested_again! if saved_change_to_not_interested_marked_at?
      CallLog.mark_not_interested_after_three_voicemails!(self)
    end
  end

  def unmark_unsure!
    with_lock do
      if archived? || converted?
        errors.add(:base, "Only active leads can be changed")
        raise ActiveRecord::RecordInvalid, self
      end
      update!(unsure_marked_at: nil)
    end
  end

  def not_interested?
    not_interested_marked_at.present? && spam_marked_at.nil? && !archived? && !converted?
  end

  def mark_not_interested!
    with_lock do
      if archived? || converted? || spam_marked_at.present?
        errors.add(:base, "Only active leads not marked as spam can be marked Not interested")
        raise ActiveRecord::RecordInvalid, self
      end
      now = Time.current
      update!(not_interested_marked_at: not_interested_marked_at || now)
      cancel_open_scheduled_calls!(at: now)
    end
  end

  def unmark_not_interested!
    with_lock do
      if archived? || converted?
        errors.add(:base, "Only active leads can be changed")
        raise ActiveRecord::RecordInvalid, self
      end
      update!(not_interested_marked_at: nil)
      record_interested_again! if saved_change_to_not_interested_marked_at?
    end
  end

  def mark_as_spam!
    with_lock do
      reject_converted_spam_review!
      tags << Tag.find_or_create_by!(name: SUSPECTED_SPAM_TAG) unless tags.exists?(name: SUSPECTED_SPAM_TAG)
      self.potential_marked_at = nil
      self.unsure_marked_at = nil
      self.not_interested_marked_at = nil
      self.spam_marked_at ||= Time.current
      archive!
      record_spam_review!("spam", "Marked as spam and archived")
    end
  end

  def mark_not_spam!
    with_lock do
      reject_converted_spam_review!
      tags.delete(tags.where(name: SUSPECTED_SPAM_TAG).to_a)
      update!(spam_marked_at: nil, archived_at: nil)
      record_spam_review!("not_spam", "Marked as not spam")
    end
  end

  def converted?
    converted_client_id.present?
  end

  def archived?
    archived_at.present?
  end

  # Deleting a lead archives it; the Archived tab restores it. Converted
  # leads are clients now and stay out of the archive.
  def archive!
    if converted?
      errors.add(:base, "Converted leads stay read-only")
      raise ActiveRecord::RecordInvalid, self
    end
    update!(archived_at: Time.current)
  end

  def unarchive!
    with_lock do
      if suspected_spam?
        mark_not_spam!
      else
        update!(archived_at: nil)
      end
    end
  end

  def readonly_after_convert?
    converted?
  end

  def existing_client_link_valid
    if existing_client_id.present? && existing_client.nil?
      errors.add(:existing_client, "must be an existing record")
    elsif existing_client && perfectbook_contact_id && existing_client.perfectbook_contact_id &&
        perfectbook_contact_id != existing_client.perfectbook_contact_id
      errors.add(:existing_client, "does not match the PerfectBook contact")
    end
  end

  def matching_client
    by_perfectbook = Client.find_by(perfectbook_contact_id: perfectbook_contact_id) if perfectbook_contact_id.present?
    existing_client || by_perfectbook || (Client.find_by(email: email.to_s.strip.downcase) if email.present?)
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
        phone_raw: phone_raw,
        country: country,
        state: state,
        kind: kind,
        source: source,
        campaign_name: campaign_name,
        referred_by_organization: referred_by_organization,
        referral_code: referral_code,
        perfectbook_contact_id: perfectbook_contact_id,
        origin_lead: self, source_collection_method: "conversion",
        **source_copy_attributes.symbolize_keys
      )
      if returning && client.phone.blank?
        client.update!(phone: phone, phone_raw: client.phone_raw.presence || phone_raw)
      end
      client.update!(ai_opt_out: true) if ai_opt_out?
      people.find_each do |person|
        next if person.email.present? && client.people.exists?(email: person.email)

        copied_person = client.people.create!(
          name: person.name, email: person.email, phone: person.phone, role: person.role,
          origin_lead: self, origin_person: person, source_collection_method: "conversion",
          **person.source_copy_attributes.symbolize_keys
        )
        person.activity_events.find_each do |event|
          ActivityEvent.create!(subject: copied_person, kind: event.kind, summary: event.summary,
            occurred_at: event.occurred_at, metadata: (event.metadata || {}).merge("from_person_id" => person.id))
        end
      end
      client.reload
      ambiguity = client.ambiguous_recipient_emails | ambiguous_recipient_emails
      source_addresses = current_recipient_emails | redirect_map.values.map { |address| resolve_redirected_email(address) }.compact_blank
      ambiguity |= source_addresses & client.redirect_map.keys
      redirects = client.redirect_map.merge(redirect_map) do |address, existing, incoming|
        ambiguity |= [ address ] if existing != incoming
        existing
      end
      ambiguity |= redirects.keys & client.current_recipient_emails
      client.update!(email_redirects: redirects, ambiguous_emails: ambiguity, pipeline_stage: "won")
      client.tags |= tags.to_a
      note_ids = {}
      ActivityEvent.suppress do
        notes.find_each do |note|
          copied_note = Note.create!(notable: client, body: note.body, author: note.author, created_at: note.created_at)
          note_ids[note.id] = copied_note.id
        end
      end
      activity_events.find_each do |event|
        next if event.kind == "call" && client.activity_events.where(kind: "call").where("json_extract(metadata, '$.from_lead_event_id') = ?", event.id).exists?
        metadata = (event.metadata || {}).merge("from_lead_id" => id, "from_lead_event_id" => event.id)
        metadata["note_id"] = note_ids.fetch(metadata["note_id"]) if note_ids.key?(metadata["note_id"])
        ActivityEvent.create!(
          subject: client, kind: event.kind, summary: event.summary,
          occurred_at: event.occurred_at, metadata: metadata
        )
      end
      tasks.update_all(subject_type: "Client", subject_id: client.id)
      scheduled_calls.update_all(client_id: client.id)
      Draft.where(owner: self, conversation_id: nil).find_each do |draft|
        draft.update!(conversation: conversations.create!(subject_line: draft.subject.presence || "New message"))
      end
      Conversation.where(linkable: self).update_all(linkable_type: "Client", linkable_id: client.id)
      EmailIdentity.where(linkable: self).update_all(linkable_type: "Client", linkable_id: client.id)
      Draft.where(owner: self).update_all(owner_type: "Client", owner_id: client.id)
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

  def display_phone
    phone.presence || phone_raw.presence
  end

  def display_email
    email.presence || people.map(&:email).find(&:present?)
  end

  def call_schedulable?
    !archived? && !converted? && !not_interested?
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
    return false if converted? || status == "lost" || not_interested?

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

  def reject_converted_spam_review!
    return unless converted?

    errors.add(:base, "Converted leads stay read-only")
    raise ActiveRecord::RecordInvalid, self
  end

  def record_spam_review!(verdict, summary)
    activity_events.create!(kind: "spam_review", summary: summary, occurred_at: Time.current,
      metadata: { "verdict" => verdict, "actor" => Current.user_email.presence || "manual" })
  end

  def record_interested_again!
    activity_events.create!(kind: "interested_again", summary: "Restored from Not interested", occurred_at: Time.current,
      metadata: { "actor" => Current.user_email.presence || "manual" })
  end

  def cancel_open_scheduled_calls!(at: Time.current)
    scheduled_calls.scheduled.order(:scheduled_at, :id).each do |call|
      call.cancel!(cancelled_at: at)
      stamp = call.scheduled_at.in_time_zone.strftime("%b %-d, %-l:%M %p").strip
      activity_events.create!(
        kind: "scheduled_call",
        summary: "Scheduled call for #{stamp} cancelled (marked not interested)",
        occurred_at: at,
        metadata: {
          "scheduled_call_id" => call.id,
          "scheduled_at" => call.scheduled_at.iso8601,
          "reason" => "not_interested",
          "actor" => Current.user_email.presence || "manual"
        }
      )
    end
  end

  def enqueue_ad_conversion
    AdConversions::LeadJob.perform_later(id) if AdConversions.reportable?(self)
  rescue StandardError => error
    Rails.logger.error("[lead] ad conversion enqueue failed: #{error.class}")
  end

  def lost_reason_required_when_lost
    return unless status == "lost" && converted_client_id.nil?

    errors.add(:lost_reason, "is required when a lead is lost") if lost_reason.blank?
  end

  def reject_converted_write
    return if allow_converted_name_sync && converted_name_sync_only?
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
    return if allow_converted_name_sync && converted_name_sync_only?

    changed = changes.keys - %w[last_activity_at updated_at]
    if changed.any? || !@pending_tag_list.nil?
      errors.add(:base, "Converted leads stay read-only")
    end
  end

  def converted_name_sync_only?
    (changes.keys - %w[name last_activity_at updated_at]).empty? && @pending_tag_list.nil?
  end

  def no_unconvert
    if converted_client_id_was.present? && converted_client_id.nil?
      errors.add(:converted_client, "cannot be removed once set")
    end
  end

  def stamp_activity
    update_column(:last_activity_at, Time.current)
  end

  def stamp_inquiry_review_fit
    return unless will_save_change_to_owner_fit_at_inquiry?
    self.owner_fit_recorded_at = Time.current
    self.owner_fit_recorded_by = Current.user_email.presence || "manual"
  end

  def audit_inquiry_review_fit
    return unless saved_change_to_owner_fit_at_inquiry?
    activity_events.create!(kind: "inquiry_fit", summary: "Inquiry fit reviewed: #{owner_fit_at_inquiry.presence || 'not reviewed'}",
      occurred_at: Time.current, metadata: { "fit" => owner_fit_at_inquiry, "prior" => owner_fit_at_inquiry_before_last_save,
        "actor" => owner_fit_recorded_by })
  end

  def assign_reference
    return if reference.present?

    attempt = 0
    loop do
      candidate = self.class.build_reference(attempt.zero? ? id : "#{id}:#{attempt}")
      begin
        self.class.transaction(requires_new: true) { update_column(:reference, candidate) }
        break
      rescue ActiveRecord::RecordNotUnique
        attempt += 1
      end
    end
  end

  def sync_fts_later
    sync_fts!
  rescue ActiveRecord::StatementInvalid
    nil
  end

  def propagate_name_change
    if skip_name_propagation
      self.skip_name_propagation = false
      return
    end
    return unless saved_change_to_name?

    old_name, new_name = saved_change_to_name
    PersonNamePropagation.call(self, old_name: old_name, new_name: new_name)
  end
end
