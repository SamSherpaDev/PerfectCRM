# One priced row on a quote. Kind trip/departure snapshots the catalog names
# and dates at build time so later PerfectBook edits never rewrite history;
# kind custom covers permits, single supplements, and extra nights.
class QuoteLine < ApplicationRecord
  KINDS = %w[trip departure custom].freeze

  attr_accessor :price_edited

  belongs_to :quote

  before_validation :sync_total

  validates :kind, inclusion: { in: KINDS }
  validates :description, presence: true
  validates :quantity, numericality: { only_integer: true, greater_than: 0 }
  validates :unit_minor, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :total_minor, numericality: { only_integer: true, greater_than_or_equal_to: 0 }

  scope :ordered, -> { order(:position, :id) }

  # Dollar display for the builder; the model keeps integer cents.
  def unit_dollars
    unit_minor.nil? ? @unit_dollars_input : format("%.2f", unit_minor / 100.0)
  end

  def unit_dollars=(value)
    @unit_dollars_input = value.to_s.strip
    self.unit_minor = QuoteMoney.parse(@unit_dollars_input)
  end

  private

  def sync_total
    self.total_minor = quantity.to_i * unit_minor.to_i
  end
end
