class Lead < ApplicationRecord
  KINDS = %w[individual company].freeze
  SOURCES = %w[google_ads meta_ads website_form email referral manual].freeze
  STATUSES = %w[new chatting quoted nudged lost].freeze
  validates :budget_band, inclusion: { in: BUDGET_BANDS }, allow_blank: true
  validates :placement, inclusion: { in: PLACEMENTS }, allow_blank: true
  validates :spam_score, numericality: { only_integer: true, greater_than_or_equal_to: 0, less_than_or_equal_to: 100 }
  validates :travel_month, numericality: { only_integer: true, greater_than_or_equal_to: 1, less_than_or_equal_to: 12, allow_nil: true }
  validates :travel_year, numericality: { only_integer: true, greater_than_or_equal_to: 2020, less_than_or_equal_to: 2100, allow_nil: true }
  validates :party_size, numericality: { only_integer: true, greater_than_or_equal_to: 1, less_than_or_equal_to: 20, allow_nil: true }
  validates :reference, uniqueness: { allow_nil: true }
