require "test_helper"
require_relative "../support/inquiry_mail_test_helper"

class InquirySafetyNetJobTest < ActiveSupport::TestCase
  include InquiryMailTestHelper
  include ActionMailer::TestHelper

  setup do
    @old_allowlist = ENV["ALLOWED_GOOGLE_EMAILS"]
    ENV["ALLOWED_GOOGLE_EMAILS"] = "owner@example.com,second@example.com"
    ActionMailer::Base.deliveries.clear
  end

  teardown do
    ENV["ALLOWED_GOOGLE_EMAILS"] = @old_allowlist
  end

  test "daily check creates New leads linked to their threads and sends one owner-only alert with each lead's CRM link" do
    messages = [ ingest_inquiry(html: true), ingest_inquiry ]
    assert_no_difference([ "Client.count", "Message.outbound.count", "AutomaticFirstReply.count", "AdConversion.count" ]) do
      assert_difference("Lead.count", 2) do
        assert_emails(1) { InquirySafetyNetJob.perform_now }
      end
    end
    mail = ActionMailer::Base.deliveries.last
    assert_equal [ "owner@example.com" ], mail.to
    assert_nil mail.cc
    assert_nil mail.bcc
    assert_equal "Unlinked inquiries: 2 added to New", mail.subject
    assert_equal "auto-generated", mail["Auto-Submitted"].value
    assert_equal "All", mail["X-Auto-Response-Suppress"].value
    body = mail.body.decoded
    assert_includes body, "2 inquiries from the last 7 days were added to New"
    messages.each do |message|
      lead = message.reload.conversation.linkable
      assert_instance_of Lead, lead
      assert_equal "new", lead.status
      assert_includes body, "http://example.com/leads/#{lead.id}"
      assert message.inquiry_alert_attempted_at
    end
    assert_operator body.length, :<, 700
    assert_empty mail.attachments
    assert_no_difference("Lead.count") do
      assert_emails(0) { InquirySafetyNetJob.perform_now }
    end
    assert_equal 2, Today::Summary.new.unlinked_inquiries.size
    new_message = ingest_inquiry
    assert_difference("Lead.count", 1) do
      assert_emails(1) { InquirySafetyNetJob.perform_now }
    end
    new_lead = new_message.reload.conversation.linkable
    assert_includes ActionMailer::Base.deliveries.last.body.decoded, "/leads/#{new_lead.id}"
    assert_includes ActionMailer::Base.deliveries.last.subject, "1 added to New"
  end

  test "a clear check, a linked inquiry, or a candidate matching an existing lead sends no email and creates no duplicate" do
    assert_emails(0) { InquirySafetyNetJob.perform_now }
    message = ingest_inquiry
    message.conversation.update!(linkable: Lead.create!(name: "Linked"))
    existing = Lead.create!(name: "Keith Almryde", email: "keith@example.com", status: "new")
    duplicate_candidate = ingest_inquiry(email: "keith@example.com")
    assert_no_difference("Lead.count") do
      assert_emails(0) { InquirySafetyNetJob.perform_now }
    end
    assert_equal existing, duplicate_candidate.reload.conversation.linkable
    assert_nil message.reload.inquiry_alert_attempted_at
  end

  test "atomic reservation prevents overlapping scans with stale results from sending twice" do
    message = ingest_inquiry
    Leads::UnlinkedInquiries.new.resolve!
    message.reload
    stale_scan = Object.new
    stale_scan.define_singleton_method(:resolve!) { }
    stale_scan.define_singleton_method(:messages) { |**| [ message ] }
    Leads::UnlinkedInquiries.stub(:new, stale_scan) do
      assert_emails(1) { 2.times { InquirySafetyNetJob.perform_now } }
    end
  end

  test "SMTP acknowledgement loss cannot trigger a duplicate alert on retry" do
    message = ingest_inquiry
    delivery = Object.new
    delivery.define_singleton_method(:deliver_now) { raise IOError, "SMTP acknowledgement lost" }
    InquirySafetyNetMailer.stub(:unlinked, delivery) do
      assert_raises(IOError) { InquirySafetyNetJob.perform_now }
    end
    assert message.reload.inquiry_alert_attempted_at
    assert_emails(0) { InquirySafetyNetJob.perform_now }
    assert_equal [ message.id ], Today::Summary.new.unlinked_inquiries.map(&:id)
  end

  test "reingesting a provider message after a successful alert does not send again" do
    message = ingest_inquiry(provider_id: "synthetic-duplicate")
    assert_emails(1) { InquirySafetyNetJob.perform_now }
    replay = ingest_inquiry(provider_id: "synthetic-duplicate")
    assert_equal message, replay
    assert_emails(0) { InquirySafetyNetJob.perform_now }
  end

  test "an imported owner alert cannot become another missing inquiry or alert loop" do
    original = ingest_inquiry
    InquirySafetyNetJob.perform_now
    raw = ActionMailer::Base.deliveries.last.to_s
    result = Mail::Ingester.ingest(parsed: Mail::Ingester.parse_raw(raw),
      provider: { message_id: "synthetic-owner-alert" })
    assert_equal :stored, result[:status]
    assert result[:message].outbound?
    assert_equal [ original.id ], Leads::UnlinkedInquiries.new.messages.map(&:id)
    assert_emails(0) { InquirySafetyNetJob.perform_now }
  end

  test "an alert delivered to the info mailbox is filtered and retries never alert again" do
    ENV["ALLOWED_GOOGLE_EMAILS"] = "info@sherpaholidays.com"
    original = ingest_inquiry(provider_id: "synthetic-self-mail-inquiry")
    assert_emails(1) { InquirySafetyNetJob.perform_now }
    mail = ActionMailer::Base.deliveries.last
    assert_equal [ "info@sherpaholidays.com" ], mail.to
    assert_equal [ "info@sherpaholidays.com" ], mail.from

    parsed = Mail::Ingester.parse_raw(mail.to_s)
    assert_no_difference([ "Message.count", "Conversation.count", "Lead.count" ]) do
      2.times do
        result = Mail::Ingester.ingest(parsed: parsed,
          provider: { message_id: "synthetic-self-mail-alert" })
        assert_equal :filtered, result[:status]
        assert_nil result[:message]
      end
    end
    assert_equal original, ingest_inquiry(provider_id: "synthetic-self-mail-inquiry")
    assert original.reload.inquiry_alert_attempted_at
    assert_equal [ original.id ], Leads::UnlinkedInquiries.new.messages.map(&:id)
    assert_empty Leads::UnlinkedInquiries.new.messages(unalerted: true)
    assert_emails(0) { 2.times { InquirySafetyNetJob.perform_now } }
  end
end
