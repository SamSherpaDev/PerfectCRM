# Per-call log for every AI attempt: purpose, prompt version, model, token
# counts, cost estimate, latency, status, and the redacted request/response
# the captain can review. Kept 90 days (see Ai::PruneCallsJob).
class AiCall < ApplicationRecord
  PURPOSES = %w[draft_reply summarize_thread suggest_next_action triage triage_confirm].freeze
  STATUSES = %w[ok error blocked off over_cap rate_limited].freeze

  belongs_to :conversation, optional: true

  validates :purpose, inclusion: { in: PURPOSES }
  validates :prompt_version, presence: true
  validates :status, inclusion: { in: STATUSES }

  scope :ordered, -> { order(created_at: :desc) }
  scope :today, -> { where("created_at >= ?", Time.current.beginning_of_day) }
  scope :expired, -> { where("created_at < ?", 90.days.ago) }

  def self.daily_cost_cents
    today.sum(:cost_cents)
  end
end
