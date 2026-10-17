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

  test "daily check sends one short owner-only alert with each missing inquiry's CRM link" do
    messages = [ ingest_inquiry(html: true), ingest_inquiry ]
    assert_no_difference([ "Lead.count", "Client.count", "Message.outbound.count" ]) do
      assert_emails(1) { InquirySafetyNetJob.perform_now }
    end
    mail = ActionMailer::Base.deliveries.last
    assert_equal [ "owner@example.com" ], mail.to
    assert_nil mail.cc
    assert_nil mail.bcc
    assert_equal "Unlinked inquiries: 2 to review", mail.subject
    assert_equal "auto-generated", mail["Auto-Submitted"].value
    assert_equal "All", mail["X-Auto-Response-Suppress"].value
    body = mail.body.decoded
    assert_includes body, "2 possible inquiries"
    messages.each do |message|
      assert_includes body, "http://example.com/inbox/#{message.conversation_id}"
      assert message.reload.inquiry_alert_attempted_at
    end
    assert_operator body.length, :<, 700
    assert_empty mail.attachments
    assert_emails(0) { InquirySafetyNetJob.perform_now }
    assert_equal 2, Today::Summary.new.unlinked_inquiries.size
    new_message = ingest_inquiry
    assert_emails(1) { InquirySafetyNetJob.perform_now }
    assert_includes ActionMailer::Base.deliveries.last.body.decoded, "/inbox/#{new_message.conversation_id}"
    assert_includes ActionMailer::Base.deliveries.last.subject, "1 to review"
  end

  test "a clear check or a linked inquiry sends no email" do
    assert_emails(0) { InquirySafetyNetJob.perform_now }
    message = ingest_inquiry
    message.conversation.update!(linkable: Lead.create!(name: "Linked"))
    assert_emails(0) { InquirySafetyNetJob.perform_now }
    assert_nil message.reload.inquiry_alert_attempted_at
  end

  test "atomic reservation prevents overlapping scans with stale results from sending twice" do
    message = ingest_inquiry
    stale_scan = Object.new
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
end
