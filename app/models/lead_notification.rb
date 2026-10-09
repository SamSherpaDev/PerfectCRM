class LeadNotification < ApplicationRecord
  belongs_to :lead
  validates :event, inclusion: { in: %w[email_copy lead.created lead.details_added auto_first_reply] }

  scope :pending, -> { where(delivered_at: nil).where("available_at <= ?", Time.current) }

  def self.enqueue_pending(lead_id = nil)
    rows = where(delivered_at: nil)
    rows = rows.where(lead_id: lead_id) if lead_id
    rows.find_each { |notification| LeadNotificationJob.set(wait_until: notification.available_at).perform_later(notification.id) }
  rescue StandardError => error
    Rails.logger.error("[lead notifications] enqueue failed: #{error.class}")
  end

  def deliver!
    claimed = self.class.pending.where(id: id).update_all(available_at: 5.minutes.from_now)
    return if claimed.zero?

    begin
      if event == "auto_first_reply"
        AutomaticFirstReplyJob.new.perform(lead_id)
      elsif event == "email_copy"
        LeadIntakeEmailJob.new.perform(lead_id)
      else
        LeadWebhookJob.new.perform(lead_id, event)
      end
      update!(delivered_at: Time.current)
    rescue StandardError
      update!(available_at: 5.minutes.from_now)
      raise
    end
  end
end
