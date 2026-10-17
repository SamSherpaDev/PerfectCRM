require "test_helper"
require_relative "../support/inquiry_mail_test_helper"

class UnlinkedInquiriesTest < ActiveSupport::TestCase
  include InquiryMailTestHelper

  test "finds four synthetic Oct 12-17 direct-visit fallback inquiries, including HTML-only mail" do
    travel_to Time.zone.local(2026, 10, 17, 16) do
      messages = [
        ingest_inquiry(received_at: 5.days.ago, html: true),
        ingest_inquiry(received_at: 4.days.ago, subject: "Website inquiry - CRM fallback"),
        ingest_inquiry(received_at: 2.days.ago, html: true, subject: "New customer message"),
        ingest_inquiry(received_at: 1.hour.ago)
      ]
      assert messages.all? { |message| message.conversation.triage? }
      assert_nil messages.first.text_body
      assert_empty Lead.all
      assert_equal messages.map(&:id), missing.map(&:id)
    end
  end

  test "finds plain and HTML inquiry-like info mail and existing explicit new-inquiry triage" do
    plain = ingest_inquiry(from: "direct@example.com", subject: "Nepal itinerary",
      body: "We would like to plan a trip for two. What dates are available?")
    html = ingest_inquiry(from: "html@example.com", subject: "A question", html: true,
      body: "<p>Can you quote a trek to Everest for our family?</p>")
    triaged = ingest_inquiry(subject: "Following up", body: "Please call me")
    triaged.conversation.update!(ai_triage: "new_inquiry")
    explicit = ingest_inquiry(subject: "An enquiry", body: "Please call to discuss our plans")
    assert_equal [ plain.id, html.id, triaged.id, explicit.id ], missing.map(&:id)
  end

  test "linked archived, lost, and converted inquiries already have a lead" do
    messages = 3.times.map { ingest_inquiry }
    archived = Lead.create!(name: "Archived")
    archived.archive!
    lost = Lead.create!(name: "Lost", status: "lost", lost_reason: "dates")
    converted = Lead.create!(name: "Converted")
    converted.convert_to_client!
    [ archived, lost, converted.converted_client ].zip(messages).each do |owner, message|
      message.conversation.update!(linkable: owner)
    end
    assert_empty missing
  end

  test "website copies match their reference or submission even when left in triage" do
    lead = Lead.create!(name: "Already saved", external_ref: "website_form:synthetic-direct-visit")
    plain = ingest_inquiry(body: "New website inquiry\nReference: #{lead.reference}\nEmail: traveler@example.com")
    html = ingest_inquiry(html: true,
      body: "<p>Website inquiry</p><p>Reference:&nbsp;<b>#{lead.reference}</b></p>")
    submission = ingest_inquiry(body: 'Website inquiry\n"submission_id": "synthetic-direct-visit"')
    assert [ plain, html, submission ].all? { |message| message.conversation.triage? }
    lead.archive!
    assert_empty missing
  end

  test "a previous inquiry from the same email cannot hide a missing website notification" do
    lead = Lead.create!(name: "Previous trip", email: "traveler@example.com", received_at: 1.month.ago)
    reference = ingest_inquiry(body: "Website inquiry\nReference: SH-MISSING\nEmail: #{lead.email}")
    submission = ingest_inquiry(body: "Website inquiry\nSubmission ID: missing-new-submission\nEmail: #{lead.email}")
    assert_equal [ reference.id, submission.id ], missing.map(&:id)
    reference.conversation.update!(linkable: lead)
    assert_equal [ submission.id ], missing.map(&:id), "an explicit link resolves the notice"
  end

  test "an inquiry thread linked only to a client without an inquiry is still missing a lead" do
    client = Client.create!(name: "Returning traveler", email: "client@example.com")
    message = ingest_inquiry(from: client.email, subject: "New Nepal trip",
      body: "Can you quote another tour?")
    assert_equal client, message.conversation.linkable
    assert_equal [ message.id ], missing.map(&:id)
  end

  test "finds human mail without inquiry keywords" do
    message = ingest_inquiry(from: "family@example.com", subject: "Holiday in Bhutan",
      body: "Could you arrange ten days for our family?")
    assert_equal [ message.id ], missing.map(&:id)
  end

  test "website copies survive automation headers and human auto-submitted no remains eligible" do
    website = ingest_inquiry(from: "noreply@example.com", headers: { "Auto-Submitted" => "auto-generated",
      "List-Unsubscribe" => "<https://example.com/unsubscribe>" })
    human = ingest_inquiry(subject: "Hello", body: "Please call", headers: { "Auto-Submitted" => "no" })
    assert_equal [ website.id, human.id ], missing.map(&:id)
  end

  test "ignores automated and bulk mail, organizations, ignored threads, and outbound mail" do
    [ { "List-Unsubscribe" => "<https://example.com/unsubscribe>" },
      { "Auto-Submitted" => "auto-generated" }, { "Precedence" => "bulk" },
      { "X-Autoreply" => "yes" } ].each do |headers|
      ingest_inquiry(subject: "Holiday in Bhutan", body: "Our latest news", headers: headers)
    end
    Organization.create!(name: "Operator", kind: "operator", email: "operator@example.com")
    ingest_inquiry(from: "operator@example.com", subject: "Rates", body: "Updated rates")
    ingest_inquiry(from: "no-reply@example.com", subject: "Notice", body: "Updated rates")
    ignored = ingest_inquiry
    ignored.conversation.update!(ignored: true)
    ingest_inquiry(subject: "Undeliverable: Nepal trip inquiry", body: "Failed")
    ingest_inquiry(subject: "Automatic reply: New inquiry from Synthetic Traveler", body: "Away")
    ingest_inquiry(from: "mailer-daemon@example.com", subject: "Failure", body: "Failed")
    outbound = ingest_inquiry
    outbound.update!(direction: "out", to_addresses: [ "traveler@example.com" ])
    assert_empty missing
  end

  test "uses received time with sent and created fallbacks and excludes old or future mail" do
    travel_to Time.zone.local(2026, 10, 17, 16) do
      old = ingest_inquiry(received_at: 8.days.ago)
      old.update!(sent_at: Time.current, created_at: Time.current)
      ingest_inquiry(received_at: 1.day.from_now)
      at_boundary = ingest_inquiry(received_at: 7.days.ago)
      sent = ingest_inquiry(received_at: 2.days.ago)
      sent.update!(inbound_received_at: nil)
      created = ingest_inquiry
      created.update!(inbound_received_at: nil, sent_at: nil, created_at: 1.day.ago)
      assert_equal [ at_boundary.id, sent.id, created.id ], missing.map(&:id)
    end
  end

  test "alerted mail remains visible until linked or ignored while only new messages are emailable" do
    message = ingest_inquiry
    message.update!(inquiry_alert_attempted_at: Time.current)
    assert_equal [ message.id ], missing.map(&:id)
    assert_empty Leads::UnlinkedInquiries.new.messages(unalerted: true)
    message.conversation.update!(linkable: Lead.create!(name: "Recovered"))
    assert_empty missing
  end

  private

  def missing
    Leads::UnlinkedInquiries.new.messages
  end
end
