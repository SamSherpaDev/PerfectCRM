class ScheduledCall < ApplicationRecord
  STATUSES = %w[scheduled completed cancelled].freeze
  DURATIONS = [ 15, 30, 45, 60 ].freeze
  QUICK_TIMES = [
    [ "9:00 AM", "09:00" ],
    [ "11:00 AM", "11:00" ],
    [ "2:00 PM", "14:00" ],
    [ "4:00 PM", "16:00" ]
  ].freeze

  belongs_to :lead
  belongs_to :activity_event, optional: true

  attr_writer :scheduled_on, :scheduled_time

  before_validation :combine_date_and_time

  validates :scheduled_at, presence: { message: "needs both a date and time" }
  validates :duration_minutes, numericality: { only_integer: true, greater_than: 0, less_than_or_equal_to: 480 }
  validates :status, inclusion: { in: STATUSES }
  validates :outcome, inclusion: { in: CallLog::OUTCOMES }, allow_blank: true
  validate :validate_schedule_inputs
  validate :lead_must_be_schedulable, if: :scheduled?

  scope :scheduled, -> { where(status: "scheduled") }
  scope :completed, -> { where(status: "completed") }
  scope :cancelled, -> { where(status: "cancelled") }
  scope :open_calls, -> { scheduled }
  scope :visible, -> {
    joins(:lead).merge(Lead.active.where(converted_client_id: nil).where.not(id: Lead.spam.select(:id)))
  }
  scope :missed, ->(now = Time.current) { scheduled.where("scheduled_calls.scheduled_at < ?", now).order(scheduled_at: :asc, id: :asc) }
  scope :upcoming, ->(now = Time.current) { scheduled.where("scheduled_calls.scheduled_at >= ?", now).order(scheduled_at: :asc, id: :asc) }
  scope :between, ->(range_start, range_end) {
    where(scheduled_at: range_start..range_end).order(scheduled_at: :asc, id: :asc)
  }
  scope :for_day, ->(date) {
    day = date.to_date
    between(day.in_time_zone.beginning_of_day, day.in_time_zone.end_of_day)
  }

  def scheduled?
    status == "scheduled"
  end

  def completed?
    status == "completed"
  end

  def cancelled?
    status == "cancelled"
  end

  def missed?(now = Time.current)
    scheduled? && scheduled_at.present? && scheduled_at < now
  end

  def today?(today = Time.zone.today)
    scheduled_at.present? && scheduled_at.in_time_zone.to_date == today
  end

  def scheduled_on
    return @scheduled_on if defined?(@scheduled_on) && !@scheduled_on.nil?

    scheduled_at&.in_time_zone&.strftime("%Y-%m-%d")
  end

  def scheduled_time
    return @scheduled_time if defined?(@scheduled_time) && !@scheduled_time.nil?

    scheduled_at&.in_time_zone&.strftime("%H:%M")
  end

  def ends_at
    return nil unless scheduled_at.present?

    scheduled_at + duration_minutes.to_i.minutes
  end

  def complete!(outcome: "connected", direction: "outbound", duration: nil, occurred_at: Time.current, save_key: nil, notes: nil)
    normalized = self.class.normalize_outcome(outcome)
    unless CallLog::OUTCOMES.include?(normalized)
      errors.add(:outcome, "is not included in the list")
      raise ActiveRecord::RecordInvalid, self
    end

    key = save_key.to_s.strip.presence
    key = "scheduled-call-#{id || SecureRandom.uuid}" unless key&.match?(/\A[\w-]{8,64}\z/)

    transaction do
      event = CallLog.record!(
        lead,
        key: key,
        occurred_at: occurred_at,
        outcome: normalized,
        direction: direction.presence || "outbound",
        duration: duration
      )
      updated_notes = notes.nil? ? self.notes : notes.to_s.strip.presence
      update!(
        status: "completed",
        outcome: normalized,
        completed_at: occurred_at,
        activity_event: event,
        notes: updated_notes
      )
      event
    end
  end

  def cancel!(cancelled_at: Time.current)
    update!(status: "cancelled", cancelled_at: cancelled_at)
  end

  def reschedule!(attributes)
    assign_attributes(attributes)
    self.status = "scheduled"
    self.cancelled_at = nil
    self.completed_at = nil
    self.outcome = nil
    save!
  end

  def self.normalize_outcome(raw)
    value = raw.to_s.strip
    return "connected" if value.blank? || value == "answered"

    value
  end

  private

  def combine_date_and_time
    @invalid_schedule_input = false
    has_on = defined?(@scheduled_on) && !@scheduled_on.nil?
    has_time = defined?(@scheduled_time) && !@scheduled_time.nil?
    return unless has_on || has_time

    date_str = (has_on ? @scheduled_on : scheduled_at&.in_time_zone&.strftime("%Y-%m-%d")).to_s.strip
    time_str = (has_time ? @scheduled_time : scheduled_at&.in_time_zone&.strftime("%H:%M")).to_s.strip

    if date_str.blank? || time_str.blank?
      self.scheduled_at = nil
      return
    end

    parsed_date = begin
      Date.iso8601(date_str)
    rescue ArgumentError
      begin
        Date.parse(date_str)
      rescue ArgumentError
        nil
      end
    end

    valid_time_format = time_str.match?(/\A(?:[01]?\d|2[0-3]):[0-5]\d(?::[0-5]\d)?(?:\s*[ap]\.?m\.?)?\z/i)
    parsed_time = Time.zone.parse("#{parsed_date.iso8601} #{time_str}") if parsed_date && valid_time_format
    if parsed_date && parsed_time
      self.scheduled_at = parsed_time
    else
      @invalid_schedule_input = true
      self.scheduled_at = nil
    end
  end

  def validate_schedule_inputs
    return unless @invalid_schedule_input

    errors.add(:scheduled_at, "is not a valid Pacific date and time")
  end

  def lead_must_be_schedulable
    return unless lead.present? && (lead.converted? || lead.archived?)

    errors.add(:base, "Calls can only be scheduled for active, unconverted leads")
  end
end
