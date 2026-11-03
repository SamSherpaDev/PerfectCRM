require "test_helper"

class TripQuizEmailJobTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  include ActionMailer::TestHelper

  setup do
    Setting.current.update!(trip_quiz_email_enabled: true, sender_name: "Sam", email_signature: "Sam\nSherpaHolidays")
    Setting.current.update_columns(trip_quiz_email_enabled_at: 1.hour.ago)
    @lead = Lead.create!(name: "Anna Lindqvist", email: "anna@gmail.com", capture_channel: "website_form",
      external_ref: "website_form:#{SecureRandom.uuid}", placement: "trip_quiz",
      metadata: { "quiz" => TripQuizEmail::SAMPLE_QUIZ })
  end

  test "queues one signed trip quiz email on the lead's timeline and delivers it once" do
    assert_enqueued_with(job: OutboundDeliveryJob) { TripQuizEmailJob.perform_now(@lead.id) }
    message = @lead.trip_quiz_email.message
    assert_no_difference([ "Message.count", "TripQuizEmail.count" ]) do
      assert_enqueued_with(job: OutboundDeliveryJob, args: [ message.id ]) { TripQuizEmailJob.perform_now(@lead.id) }
    end
    assert_equal @lead, message.owner
    assert_equal [ "anna@gmail.com" ], message.to_list
    assert_equal "Your trip match", message.subject
    assert_includes message.text_body, "15-Day Nepal Cultural and Wildlife Tour"
    assert_equal 1, message.text_body.scan("Sam\nSherpaHolidays").size
    assert_not Draft.exists?(owner: @lead)
    assert_includes Message.automatic_replies, message
    assert_not_includes Message.personal_replies, message

    assert_emails 1 do
      2.times { OutboundDeliveryJob.perform_now(message.id) }
    end
    assert message.reload.sent?
    mail = ActionMailer::Base.deliveries.last
    assert_equal "auto-generated", mail["Auto-Submitted"].value
    assert_equal "All", mail["X-Auto-Response-Suppress"].value
    assert_includes @lead.activity_events.where(kind: "automation").pluck(:summary), "Trip quiz email: sent"
  end

  test "skips and logs when the switch is off, then hands over to the automatic first reply" do
    Setting.current.update!(trip_quiz_email_enabled: false, auto_first_reply_enabled: true, auto_first_reply_enabled_at: 1.hour.ago)
    assert_no_difference([ "Message.count", "TripQuizEmail.count" ]) { TripQuizEmailJob.perform_now(@lead.id) }
    handover = @lead.lead_notifications.find_by!(event: "auto_first_reply")
    assert_equal @lead.created_at + 2.minutes, handover.available_at
    assert_nil handover.delivered_at
    assert_enqueued_with(job: LeadNotificationJob, args: [ handover.id ], at: handover.available_at)
    assert_no_enqueued_jobs(only: AutomaticFirstReplyJob)
    assert_equal [ "Trip quiz email: skipped (setting is off)" ], @lead.activity_events.where(kind: "automation").pluck(:summary)

    assert_no_difference("LeadNotification.count") { TripQuizEmailJob.perform_now(@lead.id) }
  end

  test "a queued quiz email never schedules the automatic first reply" do
    Setting.current.update!(auto_first_reply_enabled: true, auto_first_reply_enabled_at: 1.hour.ago)
    assert_no_enqueued_jobs(only: AutomaticFirstReplyJob) { TripQuizEmailJob.perform_now(@lead.id) }
    assert_not @lead.lead_notifications.exists?(event: "auto_first_reply")
    assert_not @lead.activity_events.where("summary LIKE ?", "Automatic first reply%").exists?
  end

  test "a switch-off before delivery stops the queued email" do
    TripQuizEmailJob.perform_now(@lead.id)
    message = @lead.trip_quiz_email.message
    Setting.current.update!(trip_quiz_email_enabled: false)
    assert_no_emails { OutboundDeliveryJob.perform_now(message.id) }
    assert_equal "failed", message.reload.status
    assert_equal "Trip quiz email skipped: setting is off", message.send_error
  end

  test "a transient delivery failure is not retried" do
    TripQuizEmailJob.perform_now(@lead.id)
    message = @lead.trip_quiz_email.message
    ClientMailer.stub(:outbound, ->(*) { raise Net::SMTPServerBusy, "try later" }) do
      assert_no_enqueued_jobs(only: OutboundDeliveryJob) { OutboundDeliveryJob.perform_now(message.id) }
    end
    assert_equal "failed", message.reload.status
    assert_includes @lead.activity_events.where(kind: "automation").pluck(:summary),
      "Trip quiz email: failed (delivery uncertain; not retried)"
    message.update!(status: "queued")
    assert_no_emails { OutboundDeliveryJob.perform_now(message.id) }
    assert_equal "Trip quiz email already attempted; send any further correspondence manually.", message.reload.send_error
  end

  test "a missing lead is discarded" do
    assert_nothing_raised { TripQuizEmailJob.perform_now(0) }
  end
end
