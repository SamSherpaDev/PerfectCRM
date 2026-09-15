class LeadNotificationJob < ApplicationJob
  queue_as :default
  retry_on StandardError, attempts: 6, wait: 5.minutes

  def perform(notification_id)
    LeadNotification.find_by(id: notification_id)&.deliver!
  end
end
