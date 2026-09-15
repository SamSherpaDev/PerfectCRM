# Follow-up work the captain owes a client, lead, or organization.
#
# The Today view gathers these each morning: overdue, due today, and the
# next 7 days. Completing a task appends an ActivityEvent to the subject's
# timeline; snoozing hides it until the chosen date. Automatic tasks
# (created_by "automation") are proposed by Tasks::Automatic, never sent.
class Task < ApplicationRecord
  KINDS = %w[follow_up document payment_nudge review_ask call custom].freeze
  CREATED_BY = %w[automation captain].freeze
  SUBJECT_TYPES = %w[Client Lead Organization].freeze

  KIND_LABELS = {
    "follow_up" => "Follow-up",
    "document" => "Document",
    "payment_nudge" => "Payment nudge",
    "review_ask" => "Review ask",
    "call" => "Call",
    "custom" => "Custom"
  }.freeze

  # Snooze presets offered on the Today check rows and the client task card.
  SNOOZE_PRESETS = {
    "tomorrow" => 1.day,
    "3days" => 3.days,
    "week" => 7.days
  }.freeze

  belongs_to :subject, polymorphic: true
  belongs_to :template, optional: true

  validates :title, presence: true
  validates :due_on, presence: true
  validates :kind, inclusion: { in: KINDS }
  validates :created_by, inclusion: { in: CREATED_BY }
  validates :subject_type, inclusion: { in: SUBJECT_TYPES }

  scope :open, -> { where(done_at: nil) }
  scope :done, -> { where.not(done_at: nil) }
  # Snoozed past today stays hidden; snoozed until today resurfaces.
  scope :visible, -> { open.where("snoozed_until IS NULL OR snoozed_until <= ?", Date.current) }
  scope :overdue, -> { visible.where("due_on < ?", Date.current) }
  scope :due_today, -> { visible.where(due_on: Date.current) }
  scope :upcoming, -> { visible.where(due_on: Date.current + 1..Date.current + 7) }
  scope :due_within_week, -> { visible.where("due_on <= ?", Date.current + 7) }
  scope :ordered, -> { order(:due_on, :due_at, :id) }

  def done?
    done_at.present?
  end

  def overdue?
    !done? && due_on < Date.current
  end

  def snoozed?
    snoozed_until.present? && snoozed_until > Date.current
  end

  def kind_label
    KIND_LABELS.fetch(kind)
  end

  # One tap on a check row: stamps completion and leaves a timeline trail.
  def complete!
    with_lock do
      return false if done?

      update!(done_at: Time.current)
      subject.activity_events.create!(
        kind: "task", summary: "Completed: #{title}",
        occurred_at: Time.current, metadata: { "task_id" => id, "kind" => kind }
      )
    end
    true
  end

  # Presets: "tomorrow", "3days", "week"; anything else takes an explicit date.
  def snooze!(preset, date: nil)
    target = if SNOOZE_PRESETS.key?(preset.to_s)
      Date.current + SNOOZE_PRESETS.fetch(preset.to_s)
    else
      date
    end
    return false if target.blank?

    update!(snoozed_until: target)
    true
  end
end
