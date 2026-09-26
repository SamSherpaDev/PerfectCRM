# Manual campaign spend for the Monday report. Entry rules and usage:
# README.md, "Weekly ads report".
class AdSpend < ApplicationRecord
  SOURCES = %w[google_ads meta_ads].freeze
  AMOUNT_FORMAT = /\A\d+(\.\d{1,2})?\z/

  normalizes :campaign_name, with: ->(value) { value.to_s.strip }

  before_validation :snap_week_start

  validates :week_start, presence: true
  validates :source, inclusion: { in: SOURCES }
  validates :amount_minor, numericality: { only_integer: true, greater_than_or_equal_to: 0 }, allow_nil: true
  validate :amount_entered
  validates :campaign_name, presence: true, length: { maximum: 160 },
    uniqueness: { scope: %i[week_start source], message: "already has spend for that week" }

  scope :for_week, ->(week_start) { where(week_start: week_start) }
  scope :newest_first, -> { order(week_start: :desc, source: :asc, campaign_name: :asc) }

  # Saves one entry, replacing any earlier amount for the same week,
  # channel, and campaign.
  def self.record!(week_start:, source:, campaign_name:, amount_dollars:)
    week = week_start.to_date.beginning_of_week(:monday)
    entry = find_or_initialize_by(week_start: week, source: source.to_s, campaign_name: campaign_name.to_s.strip)
    entry.amount_dollars = amount_dollars
    entry.save!
    entry
  end

  # Dollars in the form, cents in the column.
  def amount_dollars
    amount_minor.nil? ? nil : amount_minor / 100.0
  end

  def amount_dollars=(value)
    text = value.to_s.strip.delete(",$")
    self.amount_minor = text.match?(AMOUNT_FORMAT) ? (text.to_d * 100).round : nil
  end

  private

  def amount_entered
    errors.add(:base, "Enter the amount spent, like 126 or 126.50") if amount_minor.nil?
  end

  def snap_week_start
    self.week_start = week_start&.beginning_of_week(:monday)
  end
end
