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

  validates :reference, presence: true, uniqueness: true
  validates :accept_token, uniqueness: true
  validates :status, inclusion: { in: STATUSES }
  validates :currency, inclusion: { in: CURRENCIES }
  validates :deposit_minor, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :party_size, numericality: { only_integer: true, greater_than: 0, allow_nil: true }
  validates :party_size, :valid_until, presence: true, on: :send
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
    client || lead
  end

  def owner_name
    owner&.name.to_s
  end

  def owner_email
    owner&.display_email
  end

  def subject_label
    trip_name.presence || "Tailored Sherpa Holidays journey"
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
  # TODO(crm-pipeline): route this through Leads::Transition once that
  # service exists on main instead of setting status directly.
  def deliver!
    with_lock do
      return false unless sendable?

      update!(status: "sent", sent_at: Time.current, sent_by_email: Current.user_email)
      if lead && !lead.converted? && %w[new chatting].include?(lead.status)
        lead.update!(status: "quoted")
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

  def acceptable?
    %w[sent viewed].include?(status) && !expired?
  end

  def accept!
    with_lock do
      return false unless acceptable?

      update!(status: "accepted", accepted_at: Time.current,
        intake_payload: JSON.generate(intake_details))
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
    {
      "trip" => trip_name, "departure" => departure_label,
      "departure_start" => departure_start_on&.iso8601,
      "departure_end" => departure_end_on&.iso8601,
      "party_size" => party_size, "total_minor" => subtotal_minor,
      "currency" => currency, "client" => owner_name, "email" => owner_email,
      "quote_reference" => reference
    }
  end

  # Opens PerfectBook's new-booking page with the intake details as query
  # params. TODO(pb-inquiry-intake): point this at PerfectBook's
  # POST enquiry-creation endpoint once it exists, and post the staged
  # intake payload directly instead of opening the page.
  def perfectbook_intake_url
    params = {
      trip: trip_name, departure: departure_label,
      start_date: departure_start_on&.iso8601, end_date: departure_end_on&.iso8601,
      party_size: party_size, name: owner_name, email: owner_email,
      quote: reference
    }.compact_blank
    "#{PerfectBook.base_url}/bookings/new?#{params.to_query}"
  end

  private

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
