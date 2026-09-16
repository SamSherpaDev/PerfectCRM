class MailImport < ApplicationRecord
  STATUSES = %w[draft previewing preview_failed preview running done failed].freeze
  SCOPES = %w[all since_date last_n_months].freeze

  serialize :preview_json, coder: JSON

  validates :status, inclusion: { in: STATUSES }
  validates :scope, inclusion: { in: SCOPES }
  validates :months, presence: true, numericality: { only_integer: true, greater_than: 0 }, if: -> { scope == "last_n_months" }
  validates :since_date, presence: true, if: -> { scope == "since_date" }

  before_create :freeze_cutoff

  scope :ordered, -> { order(created_at: :desc) }

  def preview_rows
    rows = preview_json.is_a?(Hash) ? preview_json["rows"] : preview_json
    Array(rows)
  end

  def progress_pct
    return 0 if total_messages.to_i <= 0

    ((processed_messages.to_f / total_messages) * 100).round.clamp(0, 100)
  end

  # Mail this run accounted for but did not store, because the CRM already
  # held it: linked plus unlinked is exactly what the run stored.
  def already_held_messages
    [ processed_messages.to_i - linked_messages.to_i - skipped_messages.to_i, 0 ].max
  end

  def done?
    status == "done"
  end

  def running?
    status == "running"
  end

  def cutoff_date
    case scope
    when "since_date" then since_date
    when "last_n_months" then new_record? ? months.to_i.months.ago.to_date : since_date
    else nil
    end
  end

  def scope_label
    case scope
    when "since_date" then "Since #{since_date}"
    when "last_n_months" then "Last #{months} months"
    else "All history"
    end
  end

  private

  def freeze_cutoff
    self.since_date = cutoff_date
  end
end
