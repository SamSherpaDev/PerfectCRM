# Per-batch summary for a group departure send. Each recipient becomes its
# own Message (delivered individually, logged on its own timeline); this
# row only counts them.
class GroupSend < ApplicationRecord
  STATUSES = %w[sending complete].freeze

  belongs_to :template
  has_many :messages, dependent: :nullify

  validates :status, inclusion: { in: STATUSES }

  def sent_count
    messages.where(status: "sent").count
  end

  def failed_count
    messages.where(status: "failed").count
  end

  def pending_count
    messages.where(status: %w[queued sending]).count
  end

  def refresh_status!
    update!(status: pending_count.zero? ? "complete" : "sending") if persisted?
  end

  def departure
    PerfectBook::Departure.find_by(perfectbook_id: perfectbook_departure_id) if perfectbook_departure_id
  end
end
