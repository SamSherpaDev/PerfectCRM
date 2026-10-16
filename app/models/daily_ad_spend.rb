# Exact daily spend replaces, never prorates or adds to weekly spend.
class DailyAdSpend < ApplicationRecord
  normalizes :campaign_name, :campaign_id, :ad_id, with: ->(value) { value.to_s.strip }
  normalizes :ad_name, with: ->(value) { value.to_s.strip.presence }
  validates :spent_on, :campaign_id, :campaign_name, presence: true
  validates :campaign_name, :campaign_id, length: { maximum: 160 }
  validates :source, inclusion: { in: AdSpend::SOURCES }
  validates :currency, format: { with: /\A[A-Z]{3}\z/ }
  validates :amount_minor, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :ad_id, :ad_name, length: { maximum: 200 }
  validates :ad_name, absence: true, if: -> { ad_id.blank? }
  validates :campaign_id, uniqueness: { scope: %i[spent_on source ad_id currency] }

  scope :campaign_totals, -> { where(ad_id: "") }
  scope :ads, -> { where.not(ad_id: "") }

  def self.record!(spent_on:, source:, campaign_id:, campaign_name:, currency:, amount_minor:, ad_id: "", ad_name: nil)
    entry = find_or_initialize_by(spent_on: spent_on, source: source, campaign_id: campaign_id.to_s.strip,
      ad_id: ad_id.to_s.strip, currency: currency)
    entry.update!(campaign_name: campaign_name, amount_minor: amount_minor, ad_name: ad_name, last_posted_at: Time.current)
    entry
  end
end
