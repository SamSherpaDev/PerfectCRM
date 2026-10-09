require "test_helper"
require_relative "../support/graph_fake"

class ReplyAlertJobTest < ActiveSupport::TestCase
  include GraphMessageBuilder
  include ActiveJob::TestHelper
  include ActionMailer::TestHelper

  setup do
    @lead = Lead.create!(name: "Synthetic Traveler", email: "synthetic@gmail.com", trip_title: "Nepal tour")
    @mailbox = FakeMailbox.new
    Setting.current.update!(ms_graph_refresh_token: "refresh-0", mailbox_watched_since: 1.minute.ago)
    @fetcher = Mail::GraphFetcher.new(transport: @mailbox.transport)
    Mail::SyncJob.new.perform(fetcher: @fetcher)
  end

  def add_message(id: SecureRandom.uuid, from: @lead.email, headers: [], subject: "A question")
    message = graph_message(id: id, from: from, subject: subject)
    message["body"] = { "contentType" => "text", "content" => "Can we arrange a call? " * 40 }
    message["internetMessageHeaders"] = headers.map { |name, value| { "name" => name, "value" => value } }
    @mailbox.add("inbox", message)
    message
  end

  test "live Graph sync queues exactly one alert per provider message and Today needs an answer" do
    add_message(id: "live-reply")
    assert_enqueued_with(job: ReplyAlertJob) { Mail::SyncJob.new.perform(fetcher: @fetcher) }
    message = Message.find_by!(provider_message_id: "live-reply")
    assert_equal "pending", message.reply_alert_state
    assert_equal @lead, message.owner
    assert_equal 1, Today::Summary.new.waiting_on_you
    assert_emails 1 do
      2.times { ReplyAlertJob.perform_now(message.id) }
    end
    mail = ActionMailer::Base.deliveries.last
    assert_equal [ "info@sherpaholidays.com" ], mail.to
    assert_equal [ "info@sherpaholidays.com" ], mail.from
    assert_equal "Reply from Synthetic Traveler: Nepal tour", mail.subject
    text = mail.body.decoded
    assert_includes text, @lead.email
    assert_includes text, message.inbound_received_at.iso8601
    assert_includes text, "/inbox/#{message.conversation_id}"
    assert_includes text, message.preview_text(300)
    assert_operator text.size, :<, 650
    assert_empty mail.attachments
    assert_equal "sent", message.reload.reply_alert_state
    assert_no_enqueued_jobs(only: ReplyAlertJob) { Mail::SyncJob.new.perform(fetcher: @fetcher) }
  end

  test "alert mail is never imported and never loops even with a client's thread id" do
    add_message(id: "original-reply")
    Mail::SyncJob.new.perform(fetcher: @fetcher)
    message = Message.find_by!(provider_message_id: "original-reply")
    ReplyAlertJob.perform_now(message.id)
    alert = ActionMailer::Base.deliveries.last
    parsed = Mail::Ingester.parse_raw(alert.to_s)
    assert_equal false, Mail.keeps?(parsed.headers)
    assert_no_difference([ "Conversation.count", "Message.count" ]) do
      assert_equal :filtered, Mail::Ingester.ingest(parsed: parsed,
        provider: { message_id: "alert-self", thread_id: message.conversation.provider_thread_id }, alert: true)[:status]
    end
    @mailbox.add("inbox", graph_message(id: "self-alert", from: "info@sherpaholidays.com",
      to: "info@sherpaholidays.com", subject: alert.subject))
    assert_no_difference("Message.count") do
      assert_no_enqueued_jobs(only: ReplyAlertJob) { Mail::SyncJob.new.perform(fetcher: @fetcher) }
    end
  end

  test "lead person and client matches alert but unknown and organization senders stay quiet" do
    client = Client.create!(name: "Client", email: "client@gmail.com")
    person = @lead.people.create!(name: "Companion", email: "companion@gmail.com")
    Organization.create!(name: "Operator", email: "operator@gmail.com")
    [ client.email, person.email ].each do |email|
      add_message(from: email)
      assert_enqueued_jobs 1, only: ReplyAlertJob do
        Mail::SyncJob.new.perform(fetcher: @fetcher)
      end
    end
    [ "unknown@gmail.com", "operator@gmail.com" ].each do |email|
      add_message(from: email)
      assert_no_enqueued_jobs(only: ReplyAlertJob) { Mail::SyncJob.new.perform(fetcher: @fetcher) }
    end
  end

  [ [ "Auto-Submitted", "auto-replied" ], [ "X-Autoreply", "yes" ],
    [ "X-Autorespond", "yes" ],
    [ "X-MS-Exchange-Inbox-Rules-Loop", "mailbox" ], [ "Return-Path", "<>" ],
    [ "Content-Type", "multipart/report; report-type=delivery-status" ] ].each do |header|
    test "Graph suppresses #{header.first} automatic mail" do
      add_message(headers: [ header ])
      assert_no_enqueued_jobs(only: ReplyAlertJob) { Mail::SyncJob.new.perform(fetcher: @fetcher) }
      assert_nil Message.last.reply_alert_state
    end
  end

  test "human replies requesting automatic response suppression still alert through Graph and MIME" do
    %w[OOF None All].each do |value|
      add_message(headers: [ [ "Auto-Submitted", "no" ], [ "X-Auto-Response-Suppress", value ] ])
      assert_enqueued_jobs 1, only: ReplyAlertJob do
        Mail::SyncJob.new.perform(fetcher: @fetcher)
      end
      assert_equal "pending", Message.last.reply_alert_state

      raw = "From: #{@lead.email}\r\nTo: info@sherpaholidays.com\r\nSubject: Re: Trip\r\nAuto-Submitted: no\r\nX-Auto-Response-Suppress: #{value}\r\n\r\nCan we arrange a call?"
      assert_enqueued_jobs 1, only: ReplyAlertJob do
        result = Mail::Ingester.ingest(parsed: Mail::Ingester.parse_raw(raw),
          provider: { message_id: SecureRandom.uuid }, alert: true)
        assert_equal "pending", result[:message].reply_alert_state
      end
    end
  end

  test "raw MIME auto reply and bounce headers are retained and suppressed" do
    [ "Auto-Submitted: auto-generated", "X-Autoreply: yes", "Return-Path: <>" ].each do |header|
      raw = "From: #{@lead.email}\r\nTo: info@sherpaholidays.com\r\nSubject: Re: Trip\r\n#{header}\r\n\r\nAway"
      parsed = Mail::Ingester.parse_raw(raw)
      assert_no_enqueued_jobs(only: ReplyAlertJob) do
        result = Mail::Ingester.ingest(parsed: parsed, provider: { message_id: SecureRandom.uuid }, alert: true)
        assert_nil result[:message].reply_alert_state
      end
    end
  end

  test "sent mail out of office and bounces never alert" do
    [ "Automatic reply: trip", "Out of office", "Undeliverable: trip" ].each do |subject|
      add_message(subject: subject)
      assert_no_enqueued_jobs(only: ReplyAlertJob) { Mail::SyncJob.new.perform(fetcher: @fetcher) }
    end
    add_message(from: "mailer-daemon@gmail.com")
    @mailbox.add("sentitems", graph_message(id: "sent", from: Mail.mailbox_address, to: @lead.email))
    assert_no_enqueued_jobs(only: ReplyAlertJob) { Mail::SyncJob.new.perform(fetcher: @fetcher) }
  end

  test "provider reservation survives deletion and replay of the inbound message" do
    add_message(id: "deleted-reply")
    Mail::SyncJob.new.perform(fetcher: @fetcher)
    message = Message.find_by!(provider_message_id: "deleted-reply")
    assert_emails(1) { ReplyAlertJob.perform_now(message.id) }
    message.destroy!
    raw = "From: #{@lead.email}\r\nTo: info@sherpaholidays.com\r\nSubject: Replayed\r\n\r\nHello"
    replay = Mail::Ingester.ingest(parsed: Mail::Ingester.parse_raw(raw),
      provider: { message_id: "deleted-reply" }, alert: true)[:message]
    assert_emails(0) { ReplyAlertJob.perform_now(replay.id) }
    assert_equal "duplicate", replay.reload.reply_alert_state
  end

  test "SMTP uncertainty never retries an alert" do
    add_message(id: "uncertain-alert")
    Mail::SyncJob.new.perform(fetcher: @fetcher)
    message = Message.find_by!(provider_message_id: "uncertain-alert")
    delivery = Object.new
    def delivery.deliver_now
      raise IOError, "Acknowledgement lost"
    end
    ReplyAlertMailer.stub(:reply_received, delivery) do
      assert_raises(IOError) { ReplyAlertJob.perform_now(message.id) }
    end
    assert_emails(0) { ReplyAlertJob.perform_now(message.id) }
    assert_equal "failed", message.reload.reply_alert_state
  end

  test "history ingestion does not alert and unscheduled pending alerts can be recovered" do
    parsed = Mail::Ingester.parse_raw("From: #{@lead.email}\r\nTo: info@sherpaholidays.com\r\nSubject: Past mail\r\n\r\nHello")
    assert_no_enqueued_jobs(only: ReplyAlertJob) do
      Mail::Ingester.ingest(parsed: parsed, provider: { message_id: "history" })
    end
    add_message(id: "pending-alert")
    Mail::SyncJob.new.perform(fetcher: @fetcher)
    clear_enqueued_jobs
    assert_enqueued_jobs 1, only: ReplyAlertJob do
      ReplyAlertJob.enqueue_pending
    end
  end
end
