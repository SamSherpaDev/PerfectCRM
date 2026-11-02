require "test_helper"

class ItineraryEmailJobTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  include ActionMailer::TestHelper

  setup do
    Setting.current.update!(itinerary_email_enabled: true, sender_name: "Sam", email_signature: "Sam\nSherpaHolidays")
    Setting.current.update_columns(itinerary_email_enabled_at: 1.hour.ago)
    @lead = Lead.create!(name: "Anna Lindqvist", email: "anna@gmail.com", capture_channel: "website_form",
      external_ref: "website_form:#{SecureRandom.uuid}", placement: "itinerary_designer",
      metadata: { "itinerary" => ItineraryEmail::SAMPLE_ITINERARY })
  end

  test "queues one signed itinerary email on the lead's timeline and delivers it once" do
    assert_enqueued_with(job: OutboundDeliveryJob) { ItineraryEmailJob.perform_now(@lead.id) }
    message = @lead.itinerary_email.message
    # A replay re-enqueues the same queued message and never writes another.
    assert_no_difference([ "Message.count", "ItineraryEmail.count" ]) do
      assert_enqueued_with(job: OutboundDeliveryJob, args: [ message.id ]) { ItineraryEmailJob.perform_now(@lead.id) }
    end
    assert_equal @lead, message.owner
    assert_equal [ "anna@gmail.com" ], message.to_list
    assert_equal "Your Nepal itinerary", message.subject
    assert_includes message.text_body, "Day 1: Kathmandu"
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
    assert_includes @lead.activity_events.where(kind: "automation").pluck(:summary), "Itinerary email: sent"
  end

  test "skips and logs when the switch is off" do
    Setting.current.update!(itinerary_email_enabled: false)
    assert_no_difference([ "Message.count", "ItineraryEmail.count" ]) { ItineraryEmailJob.perform_now(@lead.id) }
    assert_equal "Itinerary email: skipped (setting is off)", @lead.activity_events.where(kind: "automation").last.summary
  end

  test "a switch-off before delivery stops the queued email" do
    ItineraryEmailJob.perform_now(@lead.id)
    message = @lead.itinerary_email.message
    Setting.current.update!(itinerary_email_enabled: false)
    assert_no_emails { OutboundDeliveryJob.perform_now(message.id) }
    assert_equal "failed", message.reload.status
    assert_equal "Itinerary email skipped: setting is off", message.send_error
  end

  test "a transient delivery failure is not retried" do
    ItineraryEmailJob.perform_now(@lead.id)
    message = @lead.itinerary_email.message
    ClientMailer.stub(:outbound, ->(*) { raise Net::SMTPServerBusy, "try later" }) do
      assert_no_enqueued_jobs(only: OutboundDeliveryJob) { OutboundDeliveryJob.perform_now(message.id) }
    end
    assert_equal "failed", message.reload.status
    assert_includes @lead.activity_events.where(kind: "automation").pluck(:summary),
      "Itinerary email: failed (delivery uncertain; not retried)"
    message.update!(status: "queued")
    assert_no_emails { OutboundDeliveryJob.perform_now(message.id) }
    assert_equal "Itinerary email already attempted; send any further correspondence manually.", message.reload.send_error
  end

  test "a missing lead is discarded" do
    assert_nothing_raised { ItineraryEmailJob.perform_now(0) }
  end
end
