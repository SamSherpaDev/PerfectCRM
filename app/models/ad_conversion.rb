# One lead outcome reported back to the ad platforms: one row per lead per
# event, so a status going back and forth never reports twice. Google pulls
# the eligible rows through the scheduled CSV feed (AdConversions::GoogleFeed);
# Meta receives each row once through the Conversions API
# (AdConversions::MetaClient). Rules live in AdConversions.
class AdConversion < ApplicationRecord
  DELIVERY_STATUSES = %w[not_sent accepted rejected unknown].freeze
  EVENTS = %w[lead qualified quote booked].freeze
  META_STATUSES = %w[not_applicable pending sending sent failed rejected uncertain skipped].freeze
  LABELS = {
    "lead" => "Inquiry", "qualified" => "Qualified inquiry",
    "quote" => "Quote sent", "booked" => "Booking (deposit paid)"
  }.freeze

  belongs_to :lead

  validates :delivery_status, inclusion: { in: DELIVERY_STATUSES }
  validates :event, inclusion: { in: EVENTS }
  validates :event, uniqueness: { scope: :lead_id }, unless: -> { event == "booked" }
  validates :perfectbook_id, presence: true, uniqueness: true, if: -> { event == "booked" && new_record? }
  belongs_to :booking, class_name: "PerfectBook::Booking", foreign_key: :perfectbook_id, primary_key: :perfectbook_id, optional: true
  validates :event_id, presence: true, uniqueness: true
  validates :meta_status, inclusion: { in: META_STATUSES }
  validates :occurred_at, presence: true
  validates :value_minor, numericality: { only_integer: true, greater_than_or_equal_to: 0 }

  scope :newest_first, -> { order(created_at: :desc, id: :desc) }
  scope :for_google, -> { where(google: true) }

  def possibly_delivered?
    %w[accepted unknown].include?(delivery_status)
  end

  def label
    LABELS.fetch(event)
  end

  def value_dollars
    value_minor / 100.0
  end

  def google_conversion_name
    AdConversions::GOOGLE_CONVERSION_NAMES[event]
  end

  def meta_event_name
    AdConversions::META_EVENT_NAMES.fetch(event)
  end
end
