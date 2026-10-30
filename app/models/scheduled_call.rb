class ScheduledCall < ApplicationRecord
  STATUSES = %w[scheduled completed cancelled].freeze
  DURATIONS = [ 15, 30, 45, 60 ].freeze
  QUICK_TIMES = [
    [ "9:00 AM", "09:00" ],
    [ "11:00 AM", "11:00" ],
    [ "2:00 PM", "14:00" ],
    [ "4:00 PM", "16:00" ]
  ].freeze

  belongs_to :lead, optional: true
  belongs_to :client, optional: true
  belongs_to :activity_event, optional: true

  attr_writer :scheduled_on, :scheduled_time

  before_validation :combine_date_and_time

  validates :scheduled_at, presence: { message: "needs both a date and time" }
  validates :duration_minutes, numericality: { only_integer: true, greater_than: 0, less_than_or_equal_to: 480 }
  validates :status, inclusion: { in: STATUSES }
  validates :outcome, inclusion: { in: CallLog::OUTCOMES }, allow_blank: true
  validate :validate_schedule_inputs
  validate :owner_must_be_schedulable, if: :scheduled?

  after_create_commit :enqueue_ad_conversion

  scope :scheduled, -> { where(status: "scheduled") }
  scope :visible, -> {
    left_joins(:lead, :client).where(
      "(scheduled_calls.client_id IS NOT NULL AND clients.archived_at IS NULL) OR " \
      "(scheduled_calls.client_id IS NULL AND scheduled_calls.lead_id IS NOT NULL AND " \
      "leads.archived_at IS NULL AND leads.converted_client_id IS NULL AND leads.not_interested_marked_at IS NULL)"
    )
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

  def owner
    client || lead
  end

  def scheduled?
    status == "scheduled"
  end

  def missed?(now = Time.current)
    scheduled? && scheduled_at.present? && scheduled_at < now
  end

  def today?(today = Time.zone.today)
    scheduled_at.present? && scheduled_at.in_time_zone.to_date == today
  end

  def due_by?(time)
    scheduled_at.in_time_zone.to_date <= time.in_time_zone.to_date
  end

  def scheduled_on
    return @scheduled_on if defined?(@scheduled_on) && !@scheduled_on.nil?

    scheduled_at&.in_time_zone&.strftime("%Y-%m-%d")
  end

  def scheduled_time
    return @scheduled_time if defined?(@scheduled_time) && !@scheduled_time.nil?

    scheduled_at&.in_time_zone&.strftime("%H:%M")
  end

  def self.complete_due_by!(event)
    lead = event.subject
    lead.with_lock do
      next if exists?(activity_event: event)

      calls = scheduled.where(lead_id: lead.id)
      client = lead.converted_client || lead.existing_client
      calls = calls.or(scheduled.where(client_id: client.id)) if client
      call = calls.order(:scheduled_at, :id).first
      next unless call&.due_by?(event.occurred_at)

      call.update!(status: "completed", outcome: event.metadata["outcome"], completed_at: event.occurred_at, activity_event: event)
    end
  end

  def complete!(outcome:, save_key:, inquiry_id: nil, occurred_at: Time.current)
    return activity_event if activity_event && activity_event.idempotency_key == save_key
    ensure_scheduled!
    unless CallLog::OUTCOMES.include?(outcome)
      errors.add(:outcome, "is not included in the list")
      raise ActiveRecord::RecordInvalid, self
    end
    inquiry = client ? client.inquiries.find_by(id: inquiry_id) : lead
    unless inquiry
      errors.add(:base, "Choose one of this client's inquiries to log the call")
      raise ActiveRecord::RecordInvalid, self
    end

    transaction do
      event = CallLog.record!(inquiry, key: save_key, occurred_at: occurred_at, outcome: outcome, direction: "outbound")
      update!(status: "completed", outcome: outcome, completed_at: occurred_at, activity_event: event)
      event
    end
  end

  def cancel!(cancelled_at: Time.current)
    ensure_scheduled!
    update!(status: "cancelled", cancelled_at: cancelled_at)
  end

  def reschedule!(attributes)
    ensure_scheduled!
    update!(attributes)
  end

  private

  def ensure_scheduled!
    return if scheduled?

    errors.add(:base, "This call is no longer scheduled")
    raise ActiveRecord::RecordInvalid, self
  end

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
      nil
    end

    if parsed_date && time_str.match?(/\A(?:[01]\d|2[0-3]):[0-5]\d\z/)
      self.scheduled_at = Time.zone.parse("#{parsed_date.iso8601} #{time_str}")
    else
      @invalid_schedule_input = true
      self.scheduled_at = nil
    end
  end

  def validate_schedule_inputs
    return unless @invalid_schedule_input

    errors.add(:scheduled_at, "is not a valid Pacific date and time")
  end

  def owner_must_be_schedulable
    if owner.nil?
      errors.add(:base, "Calls must belong to a lead or client")
    elsif client.present?
      errors.add(:base, "Calls can only be scheduled for active clients") unless client.call_schedulable?
    elsif !lead.call_schedulable?
      errors.add(:base, "Calls can only be scheduled for active, unconverted leads")
    end
  end

  def enqueue_ad_conversion
    return if client_id.present? || lead.nil?

    AdConversions::LeadJob.perform_later(lead_id) if AdConversions.reportable?(lead)
  rescue StandardError => error
    Rails.logger.error("[scheduled_call] ad conversion enqueue failed: #{error.class}")
  end
end
