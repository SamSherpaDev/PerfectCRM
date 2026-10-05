# A trip quote built from the mirrored PerfectBook catalog, sent as email
# plus PDF, and accepted by the client through an unguessable tap-to-accept
# link (/q/:token). Money truth stays in PerfectBook: on accept the CRM only
# stages an intake payload for the captain to post there (see
# TODO(pb-inquiry-intake) in #perfectbook_intake_url).
#
# Owner is exactly one of a client or a lead. Revisions form a chain through
# #parent with an incrementing #version; duplicates start a fresh chain.
class Quote < ApplicationRecord
  STATUSES = %w[draft sent viewed accepted superseded expired].freeze
  # Tabs on the quotes index. Viewed lives under Sent; Expired is derived
  # from valid_until, not a stored transition (see .expired).
  TABS = %w[draft sent accepted expired].freeze
  CURRENCIES = %w[USD].freeze

  belongs_to :client, optional: true
  belongs_to :lead, optional: true
  belongs_to :parent, class_name: "Quote", optional: true
  has_many :revisions, class_name: "Quote", foreign_key: :parent_id, dependent: :nullify
  has_many :lines, class_name: "QuoteLine", dependent: :destroy
  has_many :views, class_name: "QuoteView", dependent: :destroy

  accepts_nested_attributes_for :lines, allow_destroy: true,
    reject_if: proc { |attrs|
      attrs["id"].blank? && attrs["description"].blank? &&
        [ nil, "", "custom" ].include?(attrs["kind"]) &&
        [ "", "1" ].include?(attrs["quantity"].to_s) &&
        QuoteMoney.parse(attrs["unit_dollars"].to_s.strip) == 0
    }

  has_secure_token :accept_token

  before_validation :assign_reference, on: :create
  validate :complete_terms_for_delivery, on: :send
  validate :preserve_delivered_bundle

  BUNDLE_FIELDS = %w[terms_bundle terms_bundle_sha256 journey_kind local_operator disclosure_details trip_differences
    trip_name departure_label departure_start_on departure_end_on party_size deposit_minor balance_due_on
    currency included notes client_id lead_id reference version valid_until accept_token
    perfectbook_trip_id perfectbook_departure_id sent_at sent_by_email].freeze

  validates :reference, presence: true, uniqueness: true
  validates :accept_token, uniqueness: true
  validates :status, inclusion: { in: STATUSES }
  validates :currency, inclusion: { in: CURRENCIES }
  validates :deposit_minor, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :party_size, numericality: { only_integer: true, greater_than: 0, allow_nil: true }
  validates :party_size, :valid_until, presence: true, on: :send
  validates :valid_until, comparison: { greater_than_or_equal_to: -> { Date.current },
    message: "must be today or later" }, allow_nil: true, on: :send
  validate :exactly_one_owner
  validate :totals_cover_deposit

  scope :ordered, -> { order(created_at: :desc, id: :desc) }
  scope :for_tab, ->(tab) do
    case tab.to_s
    when "sent" then where(status: %w[sent viewed])
    when "expired" then expired
    else where(status: tab.to_s)
    end
  end
  scope :live, -> { where(status: %w[sent viewed]) }
  scope :expired, -> { live.where("valid_until IS NOT NULL AND valid_until < ?", Date.current) }

  # Dollar display for the builder: PerfectBook has no catalog price, so the
  # captain types dollars and the model keeps integer cents.
  def deposit_dollars
    deposit_minor.nil? ? @deposit_dollars_input : format("%.2f", deposit_minor / 100.0)
  end

  def deposit_dollars=(value)
    @deposit_dollars_input = value.to_s.strip
    self.deposit_minor = QuoteMoney.parse(@deposit_dollars_input)
  end

  def self.last_unit_for_trip(perfectbook_trip_id, departure_id: nil, sender_email: Current.user_email)
    return nil if perfectbook_trip_id.blank? || sender_email.blank?

    prices = QuoteLine.joins(:quote)
      .where(kind: %w[trip departure], perfectbook_trip_id: perfectbook_trip_id)
      .where(quotes: { status: %w[sent viewed accepted], sent_by_email: sender_email })
      .where.not(quotes: { sent_at: nil })
      .order("quotes.sent_at DESC", "quotes.id DESC", "quote_lines.id ASC")
    departure_price = prices.where(perfectbook_departure_id: departure_id).pick(:unit_minor) if departure_id.present?
    departure_price || prices.pick(:unit_minor)
  end

  def owner
    client || lead&.converted_client || lead
  end

  def owner_name
    terms_bundle.present? ? terms_bundle.fetch("client") : owner&.name.to_s
  end

  def owner_email
    terms_bundle.present? ? terms_bundle.fetch("email") : owner&.display_email
  end

  def subject_label
    trip_name.presence || "Custom SherpaHolidays trip"
  end

  # Money is integer minor units; lines own their totals (see QuoteLine).
  def subtotal_minor
    lines.to_a.reject(&:marked_for_destruction?).sum(&:total_minor)
  end
  alias total_minor subtotal_minor

  def balance_due_minor
    [ subtotal_minor - deposit_minor.to_i, 0 ].max
  end

  def draft?
    status == "draft"
  end

  def sendable?
    draft? && owner_email.present? && lines.any? && valid?(:send)
  end

  def expired?
    valid_until.present? && valid_until < Date.current && %w[sent viewed].include?(status)
  end

  def decided?
    %w[accepted superseded expired].include?(status)
  end

  # Sending moves a lead-owned quote's lead to quoted (manual captain action;
  # automations may only move between new, chatting and lost).
  def deliver!
    with_lock do
      return false unless sendable?

      self.terms_bundle = QuoteTerms.bundle(self)
      self.terms_bundle_sha256 = Digest::SHA256.hexdigest(JSON.generate(terms_bundle))
      update!(status: "sent", sent_at: Time.current, sent_by_email: Current.user_email)
      if lead && !lead.converted? && %w[new chatting].include?(lead.status)
        Leads::Transition.call(lead, to: "quoted", actor: :captain)
      end
      ActivityEvent.create!(
        subject: owner, kind: "quote",
        summary: "Quote #{reference} sent (#{subject_label})",
        occurred_at: Time.current, metadata: { "quote_id" => id }
      )
    end
    true
  end

  def mark_viewed!
    with_lock do
      return unless %w[sent viewed].include?(status) && !expired?

      update_columns(status: "viewed", viewed_at: viewed_at || Time.current,
        view_count: view_count.to_i + 1, updated_at: Time.current)
    end
  end

  def payment_schedule_current?
    terms_bundle.blank? || QuoteTerms.deposit_minor(self) == deposit_minor
  end

  def acceptable?
    %w[sent viewed].include?(status) && !expired? && payment_schedule_current?
  end

  def accept!(bundle_sha256: nil)
    with_lock do
      return false unless acceptable?
      return false if terms_bundle.present? && bundle_sha256 != terms_bundle_sha256

      self.accepted_at = Time.current
      self.accepted_terms_version = terms_bundle&.fetch("terms_version")
      self.accepted_bundle_sha256 = terms_bundle_sha256
      update!(status: "accepted", intake_payload: JSON.generate(intake_details))
      ActivityEvent.create!(
        subject: owner, kind: "quote",
        summary: "Quote #{reference} accepted - create the booking in PerfectBook",
        occurred_at: Time.current, metadata: { "quote_id" => id }
      )
    end
    true
  end

  # A fresh draft for the same owner with copied lines and a new token.
  def duplicate!
    copy = dup
    copy.reference = nil
    copy.status = "draft"
    copy.version = 1
    copy.parent = nil
    copy.sent_at = copy.viewed_at = copy.accepted_at = nil
    copy.sent_by_email = nil
    copy.view_count = 0
    copy.intake_payload = nil
    copy.terms_bundle = copy.terms_bundle_sha256 = nil
    copy.accepted_terms_version = copy.accepted_bundle_sha256 = nil
    copy.accept_token = self.class.generate_unique_secure_token
    lines.each do |line|
      copy.lines.build(line.attributes.except("id", "quote_id", "created_at", "updated_at"))
    end
    copy.save!
    copy
  end

  # A new draft version chained to this quote (this quote keeps its history).
  def new_revision!
    with_lock do
      return revisions.ordered.first if status == "superseded"
      return nil if decided?

      revision = duplicate!
      revision.update!(parent: self, version: version.to_i + 1)
      update!(status: "superseded")
      revision
    end
  end

  # Intake details staged on acceptance for manual entry in PerfectBook.
  def intake_details
    return JSON.parse(intake_payload) if intake_payload.present?

    {
      "trip" => trip_name, "departure" => departure_label,
      "departure_start" => departure_start_on&.iso8601,
      "departure_end" => departure_end_on&.iso8601,
      "party_size" => party_size, "total_minor" => subtotal_minor,
      "currency" => currency, "client" => owner_name, "email" => owner_email,
      "quote_reference" => reference,
      "deposit_minor" => deposit_minor, "balance_due_minor" => balance_due_minor,
      "balance_due_on" => balance_due_on&.iso8601,
      "accepted_at" => accepted_at&.iso8601,
      "accepted_terms_version" => accepted_terms_version,
      "accepted_bundle_sha256" => accepted_bundle_sha256,
      "terms_bundle" => terms_bundle
    }
  end

  # Opens PerfectBook's new-booking page with the intake details as query
  # params. TODO(pb-inquiry-intake): point this at PerfectBook's
  # POST enquiry-creation endpoint once it exists, and post the staged
  # intake payload directly instead of opening the page.
  def perfectbook_intake_url
    details = intake_details
    params = {
      trip: details["trip"], departure: details["departure"],
      start_date: details["departure_start"], end_date: details["departure_end"],
      party_size: details["party_size"], name: details["client"], email: details["email"],
      quote: details["quote_reference"],
      terms_version: details["accepted_terms_version"],
      terms_sha256: details["accepted_bundle_sha256"]
    }.compact_blank
    "#{PerfectBook.base_url}/bookings/new?#{params.to_query}"
  end

  private

  def complete_terms_for_delivery
    validates_presence_of :journey_kind, :local_operator, :trip_differences, :departure_start_on, :departure_end_on, :included, :trip_name
    errors.add(:journey_kind, "must be scheduled or private") unless %w[scheduled private].include?(journey_kind)
    details = disclosure_details || {}
    QuoteTerms::FIELDS.each do |key, label|
      value = details[key].to_s
      errors.add(:base, "Complete #{label.downcase} before sending") if value.blank? || value.match?(/_{3,}|\[.*?\]|\b(?:TBD|TODO|unknown)\b/i)
    end
    unless %w[covered not_covered].include?(details["fund_notice"])
      errors.add(:base, "Select the verified transaction-specific fund notice before sending")
    end
    if local_operator.to_s.match?(/\[|_{3,}|\b(?:TBD|TODO|unknown)\b/i)
      errors.add(:local_operator, "must be the verified legal name")
    end
    expected = QuoteTerms.deposit_minor(self)
    errors.add(:deposit_minor, "must match the master payment schedule (#{QuoteTerms.money(expected)})") if expected && deposit_minor != expected
    if departure_start_on && balance_due_on != departure_start_on - 90
      errors.add(:balance_due_on, "must be 90 days before departure")
    end
    if departure_end_on && departure_start_on && departure_end_on < departure_start_on
      errors.add(:departure_end_on, "must not precede the trip start")
    end
    if departure_start_on && departure_start_on < Date.current
      errors.add(:departure_start_on, "must not be in the past")
    end
  end

  def preserve_delivered_bundle
    return unless persisted? && terms_bundle_in_database.present?

    if BUNDLE_FIELDS.any? { |field| will_save_change_to_attribute?(field) }
      errors.add(:base, "Delivered quote documents cannot change. Make a new revision instead.")
    end
    if accepted_at_in_database && %w[accepted_at accepted_terms_version accepted_bundle_sha256 intake_payload].any? { |field| will_save_change_to_attribute?(field) }
      errors.add(:base, "Accepted terms evidence cannot change")
    end
  end

  def assign_reference
    self.reference ||= "Q-#{Date.current.year}-#{SecureRandom.alphanumeric(6).upcase}"
  end

  def exactly_one_owner
    if client_id.present? == lead_id.present?
      errors.add(:base, "Quote needs exactly one owner: a client or a lead")
    end
  end

  def totals_cover_deposit
    return if deposit_minor.to_i <= subtotal_minor

    errors.add(:deposit_minor, "cannot be more than the quote total")
  end
end
