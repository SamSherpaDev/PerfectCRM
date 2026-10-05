# Exact daily spend replaces, never prorates or adds to weekly spend.
class DailyAdSpend < ApplicationRecord
  normalizes :campaign_name, :campaign_id, with: ->(value) { value.to_s.strip }
  validates :spent_on, :campaign_id, :campaign_name, presence: true
  validates :campaign_name, :campaign_id, length: { maximum: 160 }
  validates :source, inclusion: { in: AdSpend::SOURCES }
  validates :currency, format: { with: /\A[A-Z]{3}\z/ }
  validates :amount_minor, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :campaign_id, uniqueness: { scope: %i[spent_on source currency] }

  def self.record!(spent_on:, source:, campaign_id:, campaign_name:, currency:, amount_minor:)
    entry = find_or_initialize_by(spent_on: spent_on, source: source, campaign_id: campaign_id, currency: currency)
    entry.update!(campaign_name: campaign_name, amount_minor: amount_minor)
    entry
  end
end
