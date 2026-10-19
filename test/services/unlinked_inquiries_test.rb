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
    triaged = ingest_inquiry(from: "triaged@example.com", subject: "Following up", body: "Please call me")
    triaged.conversation.update!(ai_triage: "new_inquiry")
    explicit = ingest_inquiry(from: "enquiry@example.com", subject: "An enquiry", body: "Please call to discuss our plans")
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
    lead = Lead.create!(name: "Previous trip", email: "traveler@example.com", received_at: 1.month.ago, status: "quoted")
    reference = ingest_inquiry(body: "Website inquiry\nReference: SH-MISSING\nEmail: #{lead.email}")
    submission = ingest_inquiry(body: "Website inquiry\nSubmission ID: missing-new-submission\nEmail: #{lead.email}")
    assert_equal [ reference.id, submission.id ], missing.map(&:id)

    assert_difference("Lead.count", 1) { Leads::UnlinkedInquiries.new.resolve! }
    safety_net_lead = reference.reload.conversation.linkable
    assert_not_equal lead, safety_net_lead
    assert safety_net_lead.safety_net_inquiry?
    assert_equal "new", safety_net_lead.status
    assert_equal safety_net_lead, submission.reload.conversation.linkable, "the same email joins the lead still in New"
    assert_equal [ reference.id ], missing.map(&:id)
    reference.conversation.update!(linkable: lead)
    assert_empty missing, "an explicit link resolves the notice"
  end

  test "an inquiry thread linked to a client stays on that client and is not turned into a lead" do
    client = Client.create!(name: "Returning traveler", email: "client@example.com")
    message = ingest_inquiry(from: client.email, subject: "New Nepal trip",
      body: "Can you quote another tour?")
    website = ingest_inquiry(body: "New website inquiry\nName: Returning traveler\nEmail: #{client.email}")
    website.conversation.update!(linkable: client)
    assert_equal client, message.conversation.linkable
    assert_empty missing

    assert_no_difference("Lead.count") { Leads::UnlinkedInquiries.new.resolve! }
    assert_equal client, message.reload.conversation.linkable
    assert_equal client, website.reload.conversation.linkable
    assert_empty missing
  end

  test "finds gmail-style human inquiry without inquiry keywords" do
    message = ingest_inquiry(from: "family.traveler@gmail.com", subject: "Holiday in Bhutan",
      body: "Could you arrange ten days for our family?")
    assert_equal [ message.id ], missing.map(&:id)
  end

  test "website copies survive automation headers and human auto-submitted no remains eligible" do
    website = ingest_inquiry(from: "noreply@example.com", headers: { "Auto-Submitted" => "auto-generated",
      "List-Unsubscribe" => "<https://example.com/unsubscribe>" })
    human = ingest_inquiry(from: "human@gmail.com", subject: "Hello", body: "Please call",
      headers: { "Auto-Submitted" => "no" })
    assert_equal [ website.id, human.id ], missing.map(&:id)
  end

  test "ignores automated and bulk mail, organizations, people, platform notifications, newsletters, receipts, and outbound mail" do
    [ { "List-Unsubscribe" => "<https://example.com/unsubscribe>" },
      { "Auto-Submitted" => "auto-generated" }, { "Precedence" => "bulk" },
      { "X-Autoreply" => "yes" } ].each do |headers|
      ingest_inquiry(from: "sender@example.com", subject: "Holiday in Bhutan", body: "Our latest news", headers: headers)
    end
    Organization.create!(name: "Operator", kind: "operator", email: "operator@example.com",
      website: "https://www.nepalsocialtreks.com")
    Organization.create!(name: "Gmail Guide", kind: "operator", email: "guide.operator@gmail.com")
    client = Client.create!(name: "Client Household", email: "household@example.com")
    Person.create!(client: client, name: "Known Companion", email: "partner.person@example.com")

    [
      [ "operator@example.com", "Rates", "Updated rates" ],
      [ "sales@nepalsocialtreks.com", "Ground handling", "Private 16 day program" ],
      [ "guide.operator@gmail.com", "Guide rates", "Available next month" ],
      [ "partner.person@example.com", "Checking in", "Following up on our details" ],
      [ "no-reply@example.com", "Notice", "Updated rates" ],
      [ "noreply@example.com", "Notice", "Updated rates" ],
      [ "do-not-reply@cloud-protect.net", "Quarantine digest", "3 held messages" ],
      [ "testflight_no_reply@email.apple.com", "TestFlight build", "Build is ready" ],
      [ "ads-noreply@google.com", "Google Ads", "Campaign update" ],
      [ "ads-account-noreply@ads.google.com", "Account alert", "Billing summary" ],
      [ "rep@xwf.google.com", "Google Ads consultation", "Schedule a call" ],
      [ "security@mail.instagram.com", "New login", "We noticed a new login" ],
      [ "notification@email.meta.com", "Meta alert", "Ad account update" ],
      [ "hello@buffer.com", "Scheduled post", "Your queue is empty" ],
      [ "listings_no_reply@t1.tripadvisor.com", "New review", "A traveler reviewed you" ],
      [ "info@simplefin.org", "SimpleFIN sign-in", "Sign-in link" ],
      [ "notifications@link.com", "Link code", "Your verification code" ],
      [ "notifications@e.link.com", "Link update", "Saved payment method" ],
      [ "notifications@example.com", "System alert", "Automated notification" ],
      [ "reservation@heritageaviation.in", "Heli update", "You can Unsubscribe or Update your preferences." ],
      [ "e.email@dnb.com", "D&B profile", "To unsubscribe from future emails or update your email preferences." ],
      [ "billing@vendor.example", "Your receipt from Vendor", "Amount paid: $50.00" ],
      [ "accounts@vendor.example", "Invoice #IN-83445807", "Your invoice is attached" ],
      [ "shop@vendor.example", "Order confirmation #104", "Thank you for your purchase" ],
      [ "staff@sherpaholidays.com", "Internal check", "Sent from our own domain" ],
      [ "alerts@mail.sherpaholidays.com", "Subdomain check", "Internal subdomain" ]
    ].each do |from, subject, body|
      msg = ingest_inquiry(from: from, subject: subject, body: body)
      msg.update_columns(inquiry_headers: nil, direction: "in")
    end

    own_mailbox = ingest_inquiry(from: "sender@example.com", subject: "Internal note", body: "Self copy")
    own_mailbox.update_columns(from_address: "info@sherpaholidays.com", inquiry_headers: nil, direction: "in")

    html_newsletter = ingest_inquiry(from: "promo@vendor.example", subject: "Autumn specials", html: true,
      body: "<p>Special partner rates</p><p><a href='https://vendor.example/unsub'>Unsubscribe</a></p>")
    html_newsletter.update_columns(inquiry_headers: nil)

    ignored = ingest_inquiry
    ignored.conversation.update!(ignored: true)
    ingest_inquiry(subject: "Undeliverable: Nepal trip inquiry", body: "Failed")
    ingest_inquiry(subject: "Automatic reply: New inquiry from Synthetic Traveler", body: "Away")
    ingest_inquiry(from: "mailer-daemon@example.com", subject: "Failure", body: "Failed")
    outbound = ingest_inquiry
    outbound.update!(direction: "out", to_addresses: [ "traveler@example.com" ])
    assert_empty missing

    gmail_human = ingest_inquiry(from: "real.traveler@gmail.com", subject: "Everest trek in October",
      body: "Hi, my partner and I want to trek to Everest Base Camp this autumn.")
    gmail_human.update_columns(inquiry_headers: nil)
    assert_equal [ gmail_human.id ], missing.map(&:id)
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

  test "resolve! turns website and direct email candidates into New leads linked to their threads and is idempotent" do
    received = Time.zone.local(2026, 10, 15, 9, 30)
    website = ingest_inquiry(
      received_at: received,
      subject: "New website inquiry from Priya Sharma: Bhutan Cultural Trek",
      body: "New website inquiry - reply to answer them directly.\n\n" \
            "Name: Priya Sharma\nEmail: priya@example.com\nPhone: (415) 555-0142\n" \
            "Has in mind: Bhutan Cultural Trek\n\nMessage:\nWe want to travel in April for 10 days.\n\n" \
            "Reference: SH-PRIYA\nSubmission ID: sub-priya-1"
    )
    direct = ingest_inquiry(
      received_at: received + 2.hours,
      from: " Maya Lin <maya.lin@gmail.com> ",
      subject: "Everest Base Camp in November",
      body: "Hi, can you send details for two hikers?"
    )
    direct.update_columns(inquiry_headers: nil)

    assert_difference("Lead.count", 2) do
      Leads::UnlinkedInquiries.new(now: received + 1.day).resolve!
    end
    assert_no_difference("Lead.count") do
      Leads::UnlinkedInquiries.new(now: received + 1.day).resolve!
    end

    website_lead = website.reload.conversation.linkable
    assert_instance_of Lead, website_lead
    assert_equal "new", website_lead.status
    assert_equal "website_form", website_lead.source
    assert_equal "Priya Sharma", website_lead.name
    assert_equal "priya@example.com", website_lead.email
    assert_equal "(415) 555-0142", website_lead.phone_raw
    assert_equal "+14155550142", website_lead.phone
    assert_equal "Bhutan Cultural Trek", website_lead.trip_title
    assert_equal "Bhutan Cultural Trek", website_lead.trip_interest
    assert_equal "We want to travel in April for 10 days.", website_lead.message
    assert_in_delta received.to_f, website_lead.received_at.to_f, 1.0
    assert_equal "SH-PRIYA", website_lead.reference
    assert_equal "website_form:sub-priya-1", website_lead.external_ref
    assert_equal true, website_lead.metadata["inquiry_safety_net"]

    direct_lead = direct.reload.conversation.linkable
    assert_instance_of Lead, direct_lead
    assert_equal "new", direct_lead.status
    assert_equal "email", direct_lead.source
    assert_equal "Maya Lin", direct_lead.name
    assert_equal "maya.lin@gmail.com", direct_lead.email
    assert_nil direct_lead.phone_raw
    assert_nil direct_lead.phone
    assert_nil direct_lead.trip_interest
    assert_equal "Hi, can you send details for two hikers?", direct_lead.message
    assert_in_delta (received + 2.hours).to_f, direct_lead.received_at.to_f, 1.0
    assert_equal true, direct_lead.metadata["inquiry_safety_net"]
    assert_not direct_lead.suspected_spam?

    # Untriaged safety-net leads remain visible on Today until triaged out of New.
    assert_equal [ website.id, direct.id ], Leads::UnlinkedInquiries.new(now: received + 1.day).messages.map(&:id)
    website_lead.mark_potential!
    direct_lead.mark_as_spam!
    assert_empty Leads::UnlinkedInquiries.new(now: received + 1.day).messages
  end

  test "resolve! links to an existing lead by Reference, submission ID, or the email of a lead still in New instead of creating a duplicate" do
    by_ref = Lead.create!(name: "Ref Owner", status: "quoted")
    by_sub = Lead.create!(name: "Submission Owner", external_ref: "website_form:sub-existing-99")
    by_sub.archive!
    keith = Lead.create!(name: "Keith Almryde", email: "keith.almryde@example.com", status: "new")
    chatting = Lead.create!(name: "Chatting Lead", email: "chatting.lead@example.com", status: "chatting")

    ref_msg = ingest_inquiry(body: "Website inquiry\nReference: #{by_ref.reference}\nEmail: other1@example.com")
    sub_msg = ingest_inquiry(body: 'Website inquiry\n"submission_id": "sub-existing-99"\nEmail: other2@example.com')
    keith_web = ingest_inquiry(body: "New website inquiry\nName: Keith Almryde\nEmail: keith.almryde@example.com\nMessage:\nChecking in on dates")
    keith_direct = ingest_inquiry(from: "keith.almryde@example.com", subject: "Quick question", body: "Following up on my inquiry")
    keith_direct.update_columns(inquiry_headers: nil)
    chatting_msg = ingest_inquiry(body: "New website inquiry\nName: Chatting Lead\nEmail: chatting.lead@example.com\nMessage:\nAdding our dates")

    assert_no_difference("Lead.count") do
      Leads::UnlinkedInquiries.new.resolve!
    end

    assert_equal by_ref, ref_msg.reload.conversation.linkable
    assert_equal by_sub, sub_msg.reload.conversation.linkable
    assert_equal keith, keith_web.reload.conversation.linkable
    assert_equal keith, keith_direct.reload.conversation.linkable
    assert_equal chatting, chatting_msg.reload.conversation.linkable
    assert_empty missing
  end

  test "resolve! creates a new lead when the same email belongs only to a lead already triaged out of New" do
    potential = Lead.create!(name: "Potential Lead", email: "potential.lead@example.com")
    potential.mark_potential!
    message = ingest_inquiry(email: potential.email)

    assert_difference("Lead.count", 1) { Leads::UnlinkedInquiries.new.resolve! }
    safety_net_lead = message.reload.conversation.linkable
    assert_not_equal potential, safety_net_lead
    assert_equal potential.email, safety_net_lead.email
    assert_equal [ message.id ], missing.map(&:id)
  end

  test "one failing message does not block the rest and leaves no orphan lead" do
    first = ingest_inquiry(email: "first.inquiry@example.com")
    broken = ingest_inquiry(body: "New website inquiry\nName: Broken Inquiry\nEmail: broken.inquiry@example.com\nPhone: 555-BROKEN")
    clean = ingest_inquiry(email: "clean.inquiry@example.com")
    original = ::Leads::Phone.method(:normalize)
    failing = lambda do |raw, **options|
      raise ActiveRecord::RecordInvalid if raw == "555-BROKEN"

      original.call(raw, **options)
    end

    ::Leads::Phone.stub(:normalize, failing) do
      assert_difference("Lead.count", 2) { Leads::UnlinkedInquiries.new.resolve! }
    end
    assert_instance_of Lead, first.reload.conversation.linkable
    assert_instance_of Lead, clean.reload.conversation.linkable
    assert_nil broken.reload.conversation.linkable, "a failed message leaves no orphan lead and stays unlinked"
    assert_equal [ first.id, broken.id, clean.id ], missing.map(&:id)

    assert_difference("Lead.count", 1) { Leads::UnlinkedInquiries.new.resolve! }
    assert_instance_of Lead, broken.reload.conversation.linkable
  end

  test "safety-net leads arrive untagged with no spam scoring and never trigger auto-reply or ad conversions" do
    Setting.current.update!(auto_first_reply_enabled: true, auto_first_reply_enabled_at: 1.day.ago)
    flagged_copy = ingest_inquiry(
      subject: "[Check] New inquiry from Seo Spammer: Not sure yet",
      body: "New website inquiry\nName: Seo Spammer\nEmail: spammer@gmail.com\n" \
            "Has in mind: Not sure yet\n\nMessage:\nVisit https://seo1.example and https://seo2.example and https://seo3.example for page 1!\n\n" \
            "Flagged for a check (spam score 75: seo_pitch, multiple_urls)."
    )
    signature = ingest_inquiry(from: "Ana Ruiz <ana.ruiz@gmail.com>", subject: "Trip to Nepal",
      body: "Hello, could you plan ten days for us?\n\nAna Ruiz\nhttps://ana.example\nhttps://instagram.example/ana\nwww.linkedin.example/ana")
    disposable = ingest_inquiry(from: "Temp Person <temp.person@mailinator.com>", subject: "Bhutan",
      body: "Please send prices.")
    [ signature, disposable ].each { |message| message.update_columns(inquiry_headers: nil) }

    assert_no_difference([ "AutomaticFirstReply.count", "AdConversion.count", "Message.outbound.count" ]) do
      assert_difference("Lead.count", 3) { Leads::UnlinkedInquiries.new.resolve! }
    end

    leads = [ flagged_copy, signature, disposable ].map { |message| message.reload.conversation.linkable }
    leads.each do |lead|
      assert_not lead.suspected_spam?
      assert_equal 0, lead.spam_score
      assert_empty lead.suspicion_hits
    end
    assert_nil leads.first.trip_interest
    leads.second.mark_potential!
    assert leads.second.reload.potential?
  end

  private

  def missing
    Leads::UnlinkedInquiries.new.messages
  end
end
