# Append-only log of outbound automation webhooks (lead.created,
# lead.details_added) so the Settings automations card can show what n8n
# was told and when. Rows are never updated by hand; jobs own them.
class LeadWebhookDelivery < ApplicationRecord
  EVENTS = %w[lead.created lead.details_added].freeze
  STATUSES = %w[pending delivered failed].freeze

  belongs_to :lead, optional: true

  validates :event, inclusion: { in: EVENTS }
  validates :url, presence: true
  validates :status, inclusion: { in: STATUSES }

  scope :newest_first, -> { order(created_at: :desc, id: :desc) }
end
