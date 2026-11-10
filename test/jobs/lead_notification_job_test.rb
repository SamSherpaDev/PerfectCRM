require "test_helper"
require_relative "../support/outbound_origins_test_helper"

class LeadNotificationJobTest < ActiveJob::TestCase
  include OutboundOriginsTestHelper
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

  test "enqueue_pending skips notifications with a job in flight and re-enqueues after 10 minutes" do
    assert_enqueued_with(job: LeadNotificationJob, args: [ @notification.id ]) do
      LeadNotification.enqueue_pending
    end
    assert @notification.reload.last_enqueued_at.present?

    travel 9.minutes do
      assert_no_enqueued_jobs only: LeadNotificationJob do
        LeadNotification.enqueue_pending
      end
    end

    travel 11.minutes do
      assert_enqueued_with(job: LeadNotificationJob, args: [ @notification.id ]) do
        LeadNotification.enqueue_pending
      end
    end
  end

  test "enqueue_pending leaves a notification eligible when the queue refuses the job" do
    scheduled = @lead.lead_notifications.create!(event: "auto_first_reply", available_at: 2.minutes.from_now)
    refuse = ->(*) { raise ActiveJob::EnqueueError, "queue database busy" }

    queue_adapter.stub(:enqueue, refuse) do
      queue_adapter.stub(:enqueue_at, refuse) do
        assert_no_enqueued_jobs only: LeadNotificationJob do
          LeadNotification.enqueue_pending
        end
      end
    end
    assert_nil @notification.reload.last_enqueued_at
    assert_nil scheduled.reload.last_enqueued_at

    assert_enqueued_jobs 2, only: LeadNotificationJob do
      LeadNotification.enqueue_pending
    end
    assert @notification.reload.last_enqueued_at.present?
    assert scheduled.reload.last_enqueued_at.present?
  end

  test "a delivery in progress on its last attempt is not marked gave up" do
    notification = @notification
    mailer = Object.new
    mailer.define_singleton_method(:deliver_now) do
      LeadNotification.enqueue_pending
      LeadNotificationJob.perform_now(notification.id)
    end

    @notification.update!(attempts: 19, available_at: 1.minute.ago)
    LeadIntakeMailer.stub(:inquiry_copy, mailer) do
      LeadNotificationJob.perform_now(@notification.id)
    end

    @notification.reload
    assert_equal 20, @notification.attempts
    assert @notification.delivered_at.present?
    assert_nil @notification.gave_up_at
    assert_not_includes LeadNotification.gave_up, @notification
  end

  test "an abandoned last attempt gives up once its claim expires" do
    @notification.update!(attempts: 20, available_at: 4.minutes.from_now)

    LeadNotification.enqueue_pending
    assert_nil @notification.reload.gave_up_at

    travel 5.minutes do
      assert_no_enqueued_jobs only: LeadNotificationJob do
        LeadNotification.enqueue_pending
      end
    end
    assert @notification.reload.gave_up?
  end

  test "notification gives up after 20 failed attempts and stops retrying" do
    mailer = Object.new
    def mailer.deliver_now
      raise IOError, "mail unavailable"
    end

    @notification.update!(attempts: 19, available_at: 1.minute.ago)
    LeadIntakeMailer.stub(:inquiry_copy, mailer) do
      assert_no_enqueued_jobs only: LeadNotificationJob do
        LeadNotificationJob.perform_now(@notification.id)
      end
    end

    @notification.reload
    assert_equal 20, @notification.attempts
    assert_nil @notification.delivered_at
    assert @notification.gave_up_at.present?
    assert @notification.gave_up?

    travel 15.minutes do
      assert_no_enqueued_jobs only: LeadNotificationJob do
        LeadNotification.enqueue_pending
      end
    end
  end

  test "notification older than 24 hours gives up and stops retrying" do
    @notification.update!(created_at: 25.hours.ago, available_at: 1.minute.ago)

    assert_no_enqueued_jobs only: LeadNotificationJob do
      LeadNotification.enqueue_pending
    end

    @notification.reload
    assert @notification.gave_up_at.present?
    assert @notification.gave_up?

    assert_no_difference("ActionMailer::Base.deliveries.size") do
      LeadNotificationJob.perform_now(@notification.id)
    end
  end
end
