require "test_helper"

class LeadNotificationJobTest < ActiveJob::TestCase
  setup do
    @lead = Lead.create!(name: "Visitor", email: "visitor@example.com")
    @notification = @lead.lead_notifications.create!(event: "email_copy")
  end

  test "duplicate jobs send a completed email only once" do
    assert_difference("ActionMailer::Base.deliveries.size", 1) do
      2.times { LeadNotificationJob.perform_now(@notification.id) }
    end
    assert @notification.reload.delivered_at.present?
  end

  test "failed delivery remains pending and succeeds after retry" do
    mailer = Object.new
    def mailer.deliver_now
      raise IOError, "mail unavailable"
    end
    LeadIntakeMailer.stub(:inquiry_copy, mailer) do
      assert_enqueued_with(job: LeadNotificationJob) do
        LeadNotificationJob.perform_now(@notification.id)
      end
    end
    assert_nil @notification.reload.delivered_at
    assert @notification.available_at > Time.current
    travel 6.minutes do
      assert_difference("ActionMailer::Base.deliveries.size", 1) do
        LeadNotificationJob.perform_now(@notification.id)
      end
    end
    assert @notification.reload.delivered_at.present?
  end

  test "scheduled drain recovers an expired claim" do
    @notification.update!(available_at: 1.minute.ago)
    assert_enqueued_with(job: LeadNotificationJob, args: [ @notification.id ]) do
      LeadNotification.enqueue_pending
    end
  end

  test "active claim prevents duplicate delivery" do
    @notification.update!(available_at: 5.minutes.from_now)
    assert_no_difference("ActionMailer::Base.deliveries.size") do
      LeadNotificationJob.perform_now(@notification.id)
    end
  end

  test "webhook failure retains its log and notification" do
    Setting.current.update!(lead_webhook_url: "https://n8n.example.com/hook")
    notification = @lead.lead_notifications.create!(event: "lead.created")
    http = Object.new
    def http.use_ssl=(_); end
    def http.open_timeout=(_); end
    def http.read_timeout=(_); end
    def http.request(_)
      Net::HTTPInternalServerError.new("1.1", "500", "Error")
    end
    Net::HTTP.stub(:new, http) do
      assert_enqueued_with(job: LeadNotificationJob) do
        LeadNotificationJob.perform_now(notification.id)
      end
    end
    assert_nil notification.reload.delivered_at
    assert_equal "failed", LeadWebhookDelivery.last.status
    assert_equal 500, LeadWebhookDelivery.last.http_status
  end
end
