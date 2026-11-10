require "test_helper"
require "fugit"

class OutboundDeliveryJobTest < ActiveJob::TestCase
  setup do
    @client = Client.create!(name: "Maya Gurung", email: "maya@example.com")
    ActionMailer::Base.deliveries.clear
  end

  test "delivers, marks sent, and clears the draft" do
    conversation = @client.conversations.create!(subject_line: "Hi")
    draft = conversation.create_draft!(owner: @client, body: "words")
    message = Outbound::Composer.call(owner: @client, conversation: conversation,
      params: { to: "maya@example.com", subject: "Hi", body: "Hello" })
    OutboundDeliveryJob.perform_now(message.id)
    assert message.reload.sent?
    assert_not_nil message.sent_at
    assert_equal 1, ActionMailer::Base.deliveries.size
    assert_not Draft.exists?(draft.id)
  end

  test "overlapping deliveries send the queued message only once" do
    message = Outbound::Composer.call(owner: @client,
      params: { to: @client.email, subject: "Hi", body: "Hello" })
    deliveries = 0
    transport = Object.new
    transport.define_singleton_method(:deliver_now) do
      deliveries += 1
      OutboundDeliveryJob.perform_now(message.id) if deliveries == 1
    end
    ClientMailer.stub(:outbound, transport) do
      OutboundDeliveryJob.perform_now(message.id)
    end
    assert_equal 1, deliveries
    assert message.reload.sent?
  end

  test "stale message instances cannot both acquire delivery" do
    message = Outbound::Composer.call(owner: @client,
      params: { to: @client.email, subject: "Hi", body: "Hello" })
    duplicate = Message.find(message.id)
    assert message.mark_sending!
    assert_not duplicate.mark_sending!
    assert_equal "sending", duplicate.reload.status
  end

  test "duplicate jobs do not deliver failed or sent messages" do
    message = Outbound::Composer.call(owner: @client,
      params: { to: @client.email, subject: "Hi", body: "Hello" })
    %w[failed sent].each do |status|
      message.update!(status: status)
      OutboundDeliveryJob.perform_now(message.id)
      assert_equal status, message.reload.status
    end
    assert_empty ActionMailer::Base.deliveries
  end

  test "a hard failure marks the message failed and keeps the draft" do
    conversation = @client.conversations.create!(subject_line: "Hi")
    draft = conversation.create_draft!(owner: @client, body: "keep me")
    message = Outbound::Composer.call(owner: @client, conversation: conversation,
      params: { to: "maya@example.com", subject: "Hi", body: "Hello" })
    ClientMailer.stub(:outbound, ->(*) { raise ArgumentError, "bad address" }) do
      OutboundDeliveryJob.perform_now(message.id)
    end
    assert message.reload.failed?
    assert_equal "bad address", message.send_error
    assert Draft.exists?(draft.id)
    assert_empty ActionMailer::Base.deliveries
  end

  test "a transient failure re-queues, then fails after the last attempt" do
    message = Outbound::Composer.call(owner: @client,
      params: { to: "maya@example.com", subject: "Hi", body: "Hello" })
    ClientMailer.stub(:outbound, ->(*) { raise Net::SMTPServerBusy, "try later" }) do
      perform_enqueued_jobs do
        OutboundDeliveryJob.perform_later(message.id)
      end
    end
    message.reload
    assert message.failed?
    assert_equal "try later", message.send_error
    assert_empty ActionMailer::Base.deliveries
  end

  test "OutboundDeliverySweepJob marks messages stuck in sending for more than 15 minutes as failed without resending" do
    stuck = Outbound::Composer.call(owner: @client,
      params: { to: "maya@example.com", subject: "Stuck reply", body: "Hello" })
    recent = Outbound::Composer.call(owner: @client,
      params: { to: "maya@example.com", subject: "Recent reply", body: "Hello" })
    queued = Outbound::Composer.call(owner: @client,
      params: { to: "maya@example.com", subject: "Queued reply", body: "Hello" })

    assert stuck.mark_sending!
    assert recent.mark_sending!
    stuck.update_columns(updated_at: 16.minutes.ago)
    recent.update_columns(updated_at: 10.minutes.ago)
    clear_enqueued_jobs

    assert_no_enqueued_jobs only: OutboundDeliveryJob do
      assert_equal 1, OutboundDeliverySweepJob.perform_now
    end

    stuck.reload
    assert stuck.failed?
    assert_equal "Delivery was interrupted. Check Sent Items in Outlook before retrying.", stuck.send_error
    assert_equal "sending", recent.reload.status
    assert_equal "queued", queued.reload.status
    assert_empty ActionMailer::Base.deliveries
  end

  test "OutboundDeliverySweepJob refreshes group send status when a stuck batch message is marked failed" do
    template = ::Template.create!(name: "Pre-trip", purpose: "pre_trip_briefing", subject: "Hi", body: "Hello")
    group_send = GroupSend.create!(template: template, status: "sending")
    message = Message.create!(
      group_send: group_send,
      direction: "out",
      status: "sending",
      to_addresses: [ "maya@example.com" ],
      subject: "Hi",
      text_body: "Hello"
    )
    message.update_columns(updated_at: 20.minutes.ago)

    OutboundDeliverySweepJob.perform_now

    assert message.reload.failed?
    assert_equal "Delivery was interrupted. Check Sent Items in Outlook before retrying.", message.send_error
    assert_equal "complete", group_send.reload.status
  end

  test "interrupted automatic emails swept to failed are not retried" do
    lead = Lead.create!(name: "Inquiry Traveler", email: "inquiry@real-domain.example",
      source: "website_form", capture_channel: "website_form", external_ref: "website_form:123")
    message = Outbound::Composer.call(owner: lead,
      params: { to: lead.email, subject: "Welcome", body: "Hello" })
    reservation = AutomaticFirstReply.create!(lead: lead, email: lead.email, message: message,
      delivery_attempted_at: 20.minutes.ago)
    assert message.mark_sending!
    message.update_columns(updated_at: 20.minutes.ago)

    OutboundDeliverySweepJob.perform_now
    assert message.reload.failed?
    assert_equal "Delivery was interrupted. Check Sent Items in Outlook before retrying.", message.send_error

    # Even if re-queued manually, the claimed reservation refuses a second SMTP attempt.
    Setting.current.update!(auto_first_reply_enabled: true, auto_first_reply_enabled_at: 1.day.ago)
    message.update!(status: "queued", send_error: nil)
    AutomaticFirstReply.stub(:skip_reason, nil) do
      OutboundDeliveryJob.perform_now(message.id)
    end
    assert message.reload.failed?
    assert_match(/already attempted/i, message.send_error)
    assert_not_nil reservation.reload.delivery_attempted_at
    assert_empty ActionMailer::Base.deliveries
  end

  test "the production schedule runs the stuck-send sweep every 5 minutes, in a form Solid Queue accepts" do
    entry = YAML.load_file(Rails.root.join("config/recurring.yml")).fetch("production").fetch("outbound_delivery_sweep")
    assert_equal OutboundDeliverySweepJob, entry.fetch("class").constantize

    # Solid Queue parses a recurring schedule with Fugit and refuses, at
    # boot, anything that is not a single cron.
    cron = Fugit.parse(entry.fetch("schedule"), multi: :fail)
    assert_instance_of Fugit::Cron, cron
    first = cron.next_time(Time.utc(2026, 11, 10, 12, 1))
    assert_equal 5.minutes, cron.next_time(first).to_i - first.to_i
  end
end
