class LeadNotification < ApplicationRecord
  EVENTS = %w[email_copy lead.created lead.details_added auto_first_reply itinerary_email trip_quiz_email].freeze
  EVENT_LABELS = {
    "email_copy" => "Inquiry email alert",
    "lead.created" => "lead.created webhook",
    "lead.details_added" => "lead.details_added webhook",
    "auto_first_reply" => "Automatic first reply",
    "itinerary_email" => "Itinerary email",
    "trip_quiz_email" => "Trip quiz email"
  }.freeze

  MAX_ATTEMPTS = 20
  MAX_AGE = 24.hours
  REENQUEUE_AFTER = 10.minutes
  CLAIM_WINDOW = 5.minutes

  belongs_to :lead
  validates :event, inclusion: { in: EVENTS }

  scope :active, -> { where(delivered_at: nil, gave_up_at: nil) }
  scope :pending, -> { active.where("available_at <= ?", Time.current) }
  scope :exhausted, ->(now) { where("attempts >= ? OR created_at <= ?", MAX_ATTEMPTS, now - MAX_AGE) }
  scope :retryable, ->(now) { where("attempts < ? AND created_at > ?", MAX_ATTEMPTS, now - MAX_AGE) }
  scope :gave_up, -> { where.not(gave_up_at: nil) }
  scope :newest_first, -> { order(gave_up_at: :desc, created_at: :desc, id: :desc) }

  def self.enqueue_pending(lead_id = nil)
    now = Time.current
    rows = active
    rows = rows.where(lead_id: lead_id) if lead_id
    rows.give_up_exhausted(now)

    eligible = rows.retryable(now)
      .where("last_enqueued_at IS NULL OR last_enqueued_at <= ?", now - REENQUEUE_AFTER)
    eligible.find_each do |notification|
      enqueued = if notification.available_at > now
        LeadNotificationJob.set(wait_until: notification.available_at).perform_later(notification.id)
      else
        LeadNotificationJob.perform_later(notification.id)
      end
      notification.update_columns(last_enqueued_at: now, updated_at: now) if enqueued
    end
  rescue StandardError => error
    Rails.logger.error("[lead notifications] enqueue failed: #{error.class}")
  end

  def self.give_up_exhausted(now)
    pending.exhausted(now).update_all(gave_up_at: now, updated_at: now)
  end

  def gave_up?
    gave_up_at.present?
  end

  def delivered?
    delivered_at.present?
  end

  def exhausted?(now)
    attempts >= MAX_ATTEMPTS || created_at <= now - MAX_AGE
  end

  def event_label
    EVENT_LABELS.fetch(event.to_s, event.to_s)
  end

  def deliver!
    return if delivered? || gave_up?

    now = Time.current
    if exhausted?(now)
      self.class.where(id: id).give_up_exhausted(now)
      reload
      return
    end

    claimed = self.class.pending
      .where(id: id)
      .retryable(now)
      .update_all([ "available_at = ?, attempts = attempts + 1, updated_at = ?", now + CLAIM_WINDOW, now ])
    return if claimed.zero?

    reload

    begin
      if event == "auto_first_reply"
        AutomaticFirstReplyJob.new.perform(lead_id)
      elsif event == "itinerary_email"
        ItineraryEmailJob.new.perform(lead_id)
      elsif event == "trip_quiz_email"
        TripQuizEmailJob.new.perform(lead_id)
      elsif event == "email_copy"
        LeadIntakeEmailJob.new.perform(lead_id)
      else
        LeadWebhookJob.new.perform(lead_id, event)
      end
      update!(delivered_at: Time.current)
    rescue StandardError
      now = Time.current
      if exhausted?(now)
        update!(gave_up_at: now)
      else
        update!(available_at: now + CLAIM_WINDOW)
        raise
      end
    end
  end
end
