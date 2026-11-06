require "test_helper"
require_relative "../support/google_sign_in_test_helper"

# Trip quiz contract (docs/leads-intake.md, "Trip quiz"): the trip_quiz
# placement, its stored quiz answers and matched trips, the details call
# request, ad-conversion exclusion, and the automatic match email behind its
# Settings switch.
class ApiV1LeadsTripQuizIntakeTest < ActionDispatch::IntegrationTest
  include ActionMailer::TestHelper
  include GoogleSignInTestHelper

  ORIGIN = "https://www.sherpaholidays.com"
  QUIZ = {
    "interests" => [ "temples", "jungle-safari", "lumbini" ],
    "pace" => "easy",
    "length" => "under-14",
    "season" => "not_sure",
    "group_size" => 4,
    "match" => {
      "handle" => "nepal-cultural-wildlife-tour",
      "title" => "15-Day Nepal Cultural and Wildlife Tour"
    },
    "alternates" => [
      {
        "handle" => "nepal-luxury-tour-kathmandu-chitwan-pokhara",
        "title" => "13-Day Nepal Premium Tour: Kathmandu, Chitwan & Pokhara"
      },
      {
        "handle" => "nepal-highlights-premium-tour",
        "title" => "9-Day Nepal Highlights Premium Tour"
      }
    ],
    "intent" => "email",
    "share_url" => "https://www.sherpaholidays.com/pages/find-your-perfect-trip#k=temples,jungle-safari,lumbini&p=easy&l=under-14&s=not_sure&n=4",
    "email_list" => false,
    "source" => "website"
  }.freeze

  setup do
    @settings = Setting.current
    @settings.update!(lead_webhook_url: nil, sender_name: "Sam", email_signature: "Sam\nSherpaHolidays")
    @settings.rotate_site_key!
    @site_key = @settings.site_key
  end

  def intake_body(overrides = {})
    {
      "schema" => "sherpa.inquiry.v2",
      "submission_id" => SecureRandom.uuid,
      "placement" => "trip_quiz",
      "contact" => { "name" => "Anna Lindqvist", "email" => "anna@gmail.com" },
      "message" => "Find your perfect trip: email match requested\nMatch: 15-Day Nepal Cultural and Wildlife Tour (nepal-cultural-wildlife-tour)",
      "consent" => { "contact" => true, "contact_at" => "2026-11-02T18:06:40Z", "text_version" => "2026-09-consent-v2" },
      "page" => { "url" => "https://www.sherpaholidays.com/pages/find-your-perfect-trip" },
      "timing" => { "started_at" => "2026-11-02T18:02:58Z", "submitted_at" => "2026-11-02T18:06:41Z" },
      "honeypot" => "",
      "client" => { "version" => "trip-quiz-1" },
      "quiz" => QUIZ.deep_dup
    }.deep_merge(overrides)
  end

  def post_intake(body, email_status: :valid)
    Leads::MailDomain.stub(:status, email_status) do
      post "/api/v1/leads/intake", params: JSON.generate(body),
        headers: { "CONTENT_TYPE" => "application/json", "Origin" => ORIGIN, "X-Sherpa-Site-Key" => @site_key }
    end
  end

  def post_details(body)
    post "/api/v1/leads/intake/details", params: JSON.generate(body.merge("schema" => "sherpa.inquiry.details.v1")),
      headers: { "CONTENT_TYPE" => "application/json", "Origin" => ORIGIN, "X-Sherpa-Site-Key" => @site_key }
  end

  test "a trip quiz inquiry stores its answers and matched trip on the lead" do
    post_intake intake_body
    assert_response :accepted
    lead = Lead.last
    assert_equal "trip_quiz", lead.placement
    assert_equal "nepal-cultural-wildlife-tour", lead.trip_handle
    assert_equal "15-Day Nepal Cultural and Wildlife Tour", lead.trip_title
    assert_equal 4, lead.party_size
    assert lead.timing_unknown
    quiz = lead.quiz
    assert_equal({ "handle" => "nepal-cultural-wildlife-tour", "title" => "15-Day Nepal Cultural and Wildlife Tour" }, quiz["match"])
    assert_equal 2, quiz["alternates"].size
    assert_equal [ "temples", "jungle-safari", "lumbini" ], quiz["interests"]
    assert_equal "easy", quiz["pace"]
    assert_equal "under-14", quiz["length"]
    assert_equal "not_sure", quiz["season"]
    assert_equal 4, quiz["group_size"]
    assert_equal "email", quiz["intent"]
    assert_equal false, quiz["email_list"]
    assert_not quiz.key?("client_version")
    assert_not quiz.key?("version")
    assert_equal "trip-quiz-1", lead.metadata.dig("client", "version")
    assert_equal "website", quiz["source"]
    assert_equal QUIZ["share_url"], quiz["share_url"]
    assert AdConversions.excluded?(lead)
  end

  test "a bad quiz field answers 400 naming the field and stores nothing" do
    assert_no_difference("Lead.count") do
      post_intake intake_body("quiz" => { "pace" => "sprint" })
    end
    assert_response :bad_request
    assert_equal({ "error" => "validation", "fields" => { "quiz.pace" => "invalid" } }, response.parsed_body)
  end

  test "landing posts with a plain-text quiz keep working and ignore a quiz key" do
    post_intake intake_body("placement" => "landing", "quiz" => { "pace" => "sprint" })
    assert_response :accepted
    lead = Lead.last
    assert_equal "landing", lead.placement
    assert_nil lead.quiz
    assert_nil lead.party_size
    assert_not lead.lead_notifications.exists?(event: "trip_quiz_email")
  end

  test "a caller-supplied _quiz is never stored, whatever the placement" do
    forged = { "match" => { "handle" => "evil-trip", "title" => "Claim your refund at evil . com" },
      "share_url" => "javascript:alert(document.cookie)", "group_size" => 9, "season" => "not_sure" }
    @settings.update!(trip_quiz_email_enabled: true)
    [ "landing", nil, "trip_quiz" ].each_with_index do |placement, index|
      body = intake_body("contact" => { "email" => "visitor#{index}@gmail.com" }).except("quiz").merge("_quiz" => forged)
      body = placement ? body.merge("placement" => placement) : body.except("placement")
      post_intake body
      assert_response :accepted
      lead = Lead.last
      assert_nil lead.quiz, placement.inspect
      assert_not lead.metadata.key?("quiz")
      assert_nil lead.party_size
      assert_not lead.timing_unknown
      assert_not lead.lead_notifications.exists?(event: "trip_quiz_email")
    end
  end

  test "a trip_quiz post without a quiz object is still accepted as an inquiry" do
    post_intake intake_body.except("quiz")
    assert_response :accepted
    assert_equal "trip_quiz", Lead.last.placement
    assert_nil Lead.last.quiz
  end

  test "the same quiz sent twice merges, changed answers stay their own inquiry" do
    post_intake intake_body
    assert_response :accepted
    assert_no_difference("Lead.count") { post_intake intake_body }
    assert_response :ok
    assert_difference("Lead.count", 1) do
      post_intake intake_body("quiz" => { "season" => "spring" })
    end
    assert_response :accepted
  end

  test "the trip quiz email waits a minute and only when switched on" do
    post_intake intake_body
    assert_not Lead.last.lead_notifications.exists?(event: "trip_quiz_email")

    @settings.update!(trip_quiz_email_enabled: true)
    freeze_time do
      post_intake intake_body("contact" => { "email" => "bea@gmail.com" })
      notification = Lead.last.lead_notifications.find_by!(event: "trip_quiz_email")
      assert_equal 1.minute.from_now, notification.available_at
    end
  end

  test "while the quiz email is off, the general first reply greets a quiz visitor as for a landing inquiry" do
    @settings.update!(trip_quiz_email_enabled: false, auto_first_reply_enabled: true, auto_first_reply_enabled_at: 1.hour.ago)
    Template.create!(name: "First reply", purpose: :first_reply, channel: "email", body: "Hi {{first_name}}, let's arrange a call.")
    travel 1.second
    post_intake intake_body
    lead = Lead.last
    assert_not lead.lead_notifications.exists?(event: "trip_quiz_email")
    first_reply_notification = lead.lead_notifications.find_by!(event: "auto_first_reply")

    travel 2.minutes
    assert_difference("Message.outbound.count", 1) { LeadNotificationJob.perform_now(first_reply_notification.id) }
    assert_equal [ "anna@gmail.com" ], AutomaticFirstReply.find_by!(lead: lead).message.to_list
    assert_nil lead.reload.trip_quiz_email
  end

  test "switched on, a trip_quiz post without quiz gets the general first reply" do
    @settings.update!(trip_quiz_email_enabled: true, auto_first_reply_enabled: true, auto_first_reply_enabled_at: 1.hour.ago)
    post_intake intake_body.except("quiz")
    lead = Lead.last
    assert_not lead.lead_notifications.exists?(event: "trip_quiz_email")
    assert lead.lead_notifications.exists?(event: "auto_first_reply")
  end

  test "a skipped quiz email hands over to the general first reply, which sends once" do
    @settings.update!(trip_quiz_email_enabled: true, auto_first_reply_enabled: true, auto_first_reply_enabled_at: 1.hour.ago)
    Template.create!(name: "First reply", purpose: :first_reply, channel: "email", body: "Hi {{first_name}}, let's arrange a call.")
    3.times { TripQuizEmail.create!(email: "anna@gmail.com") }
    travel 1.second
    post_intake intake_body
    lead = Lead.last
    assert_not lead.lead_notifications.exists?(event: "auto_first_reply")
    quiz_notification = lead.lead_notifications.find_by!(event: "trip_quiz_email")

    travel 1.minute
    assert_no_difference("Message.outbound.count") { LeadNotificationJob.perform_now(quiz_notification.id) }
    assert quiz_notification.reload.delivered_at
    first_reply_notification = lead.lead_notifications.find_by!(event: "auto_first_reply")
    assert_equal lead.created_at + 2.minutes, first_reply_notification.available_at
    assert_no_enqueued_jobs(only: AutomaticFirstReplyJob)

    travel 1.minute
    assert_difference("Message.outbound.count", 1) { LeadNotificationJob.perform_now(first_reply_notification.id) }
    assert first_reply_notification.reload.delivered_at
    assert_nil lead.reload.trip_quiz_email
    assert_equal [ "anna@gmail.com" ], AutomaticFirstReply.find_by!(lead: lead).message.to_list
    assert_includes lead.activity_events.where(kind: "automation").pluck(:summary),
      "Trip quiz email: skipped (daily limit for this address)"
    assert_no_difference("Message.outbound.count") { TripQuizEmailJob.perform_now(lead.id) }
  end

  test "switched on, the visitor gets one match email and no first reply" do
    @settings.update!(trip_quiz_email_enabled: true, auto_first_reply_enabled: true, auto_first_reply_enabled_at: 1.hour.ago)
    Template.create!(name: "First reply", purpose: :first_reply, channel: "email", body: "Hi {{first_name}}, let's arrange a call.")
    travel 1.second
    post_intake intake_body
    lead = Lead.last
    quiz_notification = lead.lead_notifications.find_by!(event: "trip_quiz_email")
    assert_not lead.lead_notifications.exists?(event: "auto_first_reply")

    travel 2.minutes
    assert_no_enqueued_jobs(only: AutomaticFirstReplyJob) do
      assert_difference("Message.outbound.count", 1) { LeadNotificationJob.perform_now(quiz_notification.id) }
    end
    message = lead.trip_quiz_email.message
    assert_equal "Your trip match", message.subject
    assert_equal [ "anna@gmail.com" ], message.to_list
    assert_emails(1) { perform_enqueued_jobs(only: OutboundDeliveryJob) }
    assert_not AutomaticFirstReply.exists?(lead: lead)
  end

  test "a quiz message carrying the product URL and share link still gets the match email" do
    @settings.update!(trip_quiz_email_enabled: true)
    message = <<~TEXT
      Find your perfect trip (quiz)
      Asked for: their match by email
      Best match: 15-Day Nepal Cultural and Wildlife Tour - https://www.sherpaholidays.com/products/nepal-cultural-wildlife-tour
      Also close: 13-Day Nepal Premium Tour: Kathmandu, Chitwan & Pokhara; 9-Day Nepal Highlights Premium Tour
      Their answers: Interests: Temples and old cities, Jungle safari, Lumbini; Pace: Easy; Length: Under two weeks; When: Not sure yet; Travelers: 4
      Link: #{QUIZ["share_url"]}
      Trip notes by email: no
    TEXT
    travel 1.second
    post_intake intake_body("message" => message)
    assert_response :accepted
    lead = Lead.last
    assert_equal 0, lead.spam_score
    notification = lead.lead_notifications.find_by!(event: "trip_quiz_email")

    travel 2.minutes
    assert_difference("Message.outbound.count", 1) { LeadNotificationJob.perform_now(notification.id) }
    assert_equal "Your trip match", lead.trip_quiz_email.message.subject
  end

  test "contact-only quiz leads persist and appear on the real leads list without invented names or consent" do
    @settings.update!(trip_quiz_email_enabled: true)
    [ { "email" => "quiz-preview@gmail.com" }, { "phone_raw" => "(415) 555-0134" } ].each do |contact|
      body = intake_body.merge("contact" => contact)
      body["quiz"].delete("intent")
      assert_difference("Lead.count", 1) { post_intake body }
      assert_response :accepted
      lead = Lead.last
      receipt = response.parsed_body
      assert_equal true, receipt["accepted"]
      assert_equal lead.id, receipt["id"]
      assert_equal lead.reference, receipt["reference"]
      assert receipt["received_at"].present?
      assert_not receipt.key?("contact")
      assert_not receipt.key?("quiz")
      assert_equal "", lead.name
      if contact["email"]
        assert_equal contact["email"], lead.email
        assert_nil lead.phone
      else
        assert_nil lead.email
        assert_equal "+14155550134", lead.phone
      end
      assert_equal false, lead.quiz["email_list"]
      assert_nil lead.call_request
      assert_equal QUIZ.slice("interests", "pace", "length", "season", "group_size"), lead.quiz.slice("interests", "pace", "length", "season", "group_size")
      assert lead.lead_notifications.exists?(event: "email_copy")
      assert_equal contact["email"].present?, lead.lead_notifications.exists?(event: "trip_quiz_email")
      assert_not lead.lead_notifications.exists?(event: "auto_first_reply")

      sign_in
      get leads_path
      assert_response :ok
      assert_select "a[href^=?]", lead_path(lead), text: (contact["email"] || "415-555-0134")
      get lead_path(lead)
      assert_response :ok
      assert_includes response.body, "Under two weeks"
    end
  end

  test "a nameless phone-only quiz lead is labeled by its phone in the Today call queue" do
    post_intake intake_body.merge("contact" => { "phone_raw" => "(415) 555-0134" })
    lead = Lead.last
    sign_in
    get root_path
    assert_response :ok
    assert_select "#call_list_lead_#{lead.id} a[href=?]", lead_path(lead), text: "415-555-0134"
  end

  test "phone-only quiz retries replay by submission id and a fresh id creates its own lead" do
    body = intake_body.merge("contact" => { "phone_raw" => "+44 20 7946 0958" })
    post_intake body
    assert_response :accepted
    lead = Lead.last
    assert_equal "+442079460958", lead.phone
    assert_no_difference("Lead.count") { post_intake body }
    assert_response :ok
    assert_equal lead.id, response.parsed_body["id"]
    assert_equal true, response.parsed_body["accepted"]

    assert_difference("Lead.count", 1) { post_intake body.merge("submission_id" => SecureRandom.uuid) }
    assert_response :accepted
    assert_not_equal lead.id, response.parsed_body["id"]
    assert_equal "+442079460958", Lead.last.phone
  end

  test "email duplicates keep every accepted contact and answer" do
    post_intake intake_body("contact" => { "phone_raw" => "4155550134" })
    with_phone = Lead.last
    assert_difference("Lead.count", 1) do
      post_intake intake_body("contact" => { "phone_raw" => "+44 20 7946 0958" })
    end
    assert_response :accepted
    assert_equal "+442079460958", Lead.last.phone

    assert_difference("Lead.count", 1) do
      post_intake intake_body("quiz" => { "season" => "spring" })
    end
    assert_equal "spring", Lead.last.quiz["season"]

    nameless = intake_body.merge("contact" => { "email" => "quiz-repeat@gmail.com" })
    post_intake nameless
    original = Lead.last
    assert_no_difference("Lead.count") do
      post_intake nameless.merge("submission_id" => SecureRandom.uuid, "contact" => { "name" => "Quinn Repeat", "email" => "quiz-repeat@gmail.com", "phone_raw" => "4155550199" })
    end
    assert_response :ok
    assert_equal original.id, response.parsed_body["id"]
    original.reload
    assert_equal "Quinn Repeat", original.name
    assert_equal "+14155550199", original.phone
    assert_equal "+14155550134", with_phone.reload.phone
  end

  test "quiz rejects missing and invalid supplied contact even when the other field is valid" do
    [ [ {}, "contact" ], [ { "phone_raw" => "1234567" }, "contact.phone_raw" ],
      [ { "email" => "bad", "phone_raw" => "4155550134" }, "contact.email" ],
      [ { "email" => "quiz@gmail.com", "phone_raw" => "+999 123456789" }, "contact.phone_raw" ] ].each do |contact, key|
      assert_no_difference("Lead.count") do
        post_intake intake_body.merge("contact" => contact), email_status: (contact["email"] == "bad" ? :invalid : :valid)
      end
      assert_response :bad_request
      assert response.parsed_body["fields"].key?(key)
    end
  end

  test "DNS temporary failure alone is retryable and never an accepted lead even alongside a valid phone" do
    assert_no_difference("Lead.count") do
      post_intake intake_body("contact" => { "phone_raw" => "4155550134" }), email_status: :temporary
    end
    assert_response :service_unavailable
    assert_equal "30", response.headers["Retry-After"]
    assert_equal "contact_validation_unavailable", response.parsed_body["error"]
    assert_not response.parsed_body.key?("accepted")
  end

  test "definite field errors win over a temporary DNS result" do
    [ [ intake_body("contact" => { "phone_raw" => "1234567" }), "contact.phone_raw" ],
      [ intake_body("consent" => { "contact" => false }), "consent.contact" ] ].each do |body, key|
      assert_no_difference("Lead.count") { post_intake body, email_status: :temporary }
      assert_response :bad_request
      assert_nil response.headers["Retry-After"]
      assert_equal "validation", response.parsed_body["error"]
      assert_equal "invalid", response.parsed_body.dig("fields", key)
      assert_not response.parsed_body["fields"].key?("contact.email")
    end
  end

  test "nameless email gets the existing match email and phone-only gets only the internal inquiry copy" do
    @settings.update!(trip_quiz_email_enabled: true, auto_first_reply_enabled: true, auto_first_reply_enabled_at: 1.hour.ago)
    travel 1.second
    post_intake intake_body.merge("contact" => { "email" => "  QUIZ-MATCH@GMAIL.COM  " })
    assert_response :accepted
    email_lead = Lead.last
    assert_equal "quiz-match@gmail.com", email_lead.email
    email_notification = email_lead.lead_notifications.find_by!(event: "trip_quiz_email")
    travel 2.minutes
    assert_difference("Message.outbound.count", 1) { LeadNotificationJob.perform_now(email_notification.id) }
    assert_equal "Your trip match", email_lead.trip_quiz_email.message.subject
    assert_equal [ "quiz-match@gmail.com" ], email_lead.trip_quiz_email.message.to_list
    assert_emails(1) { perform_enqueued_jobs(only: OutboundDeliveryJob) }

    phone_body = intake_body.merge("contact" => { "phone_raw" => "4155550134" })
    phone_body["quiz"].delete("intent")
    post_intake phone_body
    phone_lead = Lead.last
    assert_equal [ "email_copy", "lead.created" ], phone_lead.lead_notifications.order(:id).pluck(:event)
    ActionMailer::Base.deliveries.clear
    assert_no_difference("Message.outbound.count") do
      phone_lead.lead_notifications.each { |notification| LeadNotificationJob.perform_now(notification.id) }
    end
    assert_equal [ [ "info@sherpaholidays.com" ] ], ActionMailer::Base.deliveries.map(&:to)
    assert_includes ActionMailer::Base.deliveries.last.subject, "Call now"
    assert_includes ActionMailer::Base.deliveries.last.body.to_s, "tel:+14155550134"
    assert_nil phone_lead.call_request
    assert_nil phone_lead.trip_quiz_email
  end

  test "while the quiz email is off a nameless email visitor is not promised the first reply" do
    @settings.update!(trip_quiz_email_enabled: false, auto_first_reply_enabled: true, auto_first_reply_enabled_at: 1.hour.ago)
    Template.create!(name: "First reply", purpose: :first_reply, channel: "email", body: "Hi {{first_name}}, let's arrange a call.")
    travel 1.second
    post_intake intake_body.merge("contact" => { "email" => "quiz-nameless@gmail.com" })
    assert_response :accepted
    lead = Lead.last
    assert_not lead.lead_notifications.exists?(event: "trip_quiz_email")
    notification = lead.lead_notifications.find_by!(event: "auto_first_reply")
    travel 2.minutes
    assert_no_difference("Message.outbound.count") { LeadNotificationJob.perform_now(notification.id) }
    assert_nil AutomaticFirstReply.find_by(lead: lead)
    assert_nil lead.reload.trip_quiz_email
  end

  test "quiz save failure is never accepted and nonquiz still needs name and email" do
    unsaved = Lead.new
    unsaved.define_singleton_method(:save) { false }
    Lead.stub(:new, unsaved) { post_intake intake_body }
    assert_response :internal_server_error
    assert_not response.parsed_body["accepted"]
    assert_no_difference("Lead.count") do
      post_intake intake_body("placement" => "landing").merge("contact" => { "phone_raw" => "4155550134" })
    end
    assert_response :bad_request
    assert_equal "invalid", response.parsed_body.dig("fields", "contact.name")
    assert_equal "invalid", response.parsed_body.dig("fields", "contact.email")
  end

  test "quiz requires all five answers and a bot receipt cannot unlock" do
    body = intake_body
    body["quiz"].delete("season")
    assert_no_difference("Lead.count") { post_intake body }
    assert_response :bad_request
    assert_equal "invalid", response.parsed_body.dig("fields", "quiz.season")
    post_intake intake_body("honeypot" => "bot")
    assert_response :accepted
    assert_equal false, response.parsed_body["accepted"]
  end

  test "details accept a windowless call request and a sheet phone number without overwriting an existing phone" do
    post_intake intake_body
    lead = Lead.last
    submission_id = lead.external_ref.delete_prefix("website_form:")
    assert_nil lead.phone

    post_details("submission_id" => submission_id, "contact" => { "phone_raw" => "+44 20 7946 0958" },
      "call_request" => { "timezone" => "America/Los_Angeles" })
    assert_response :ok
    lead.reload
    assert_equal "+44 20 7946 0958", lead.phone_raw
    assert_equal "+442079460958", lead.phone
    assert_equal "America/Los_Angeles", lead.call_request["timezone"]
    assert_nil lead.call_request["window"]
    assert lead.call_request["requested_at"].present?
    assert_match(/Free call requested: as soon as possible \(America\/Los_Angeles\)\./, lead.notes.last.body)

    assert_no_difference("Note.count") do
      post_details("submission_id" => submission_id, "contact" => { "phone_raw" => "+1 (415) 555-0134" },
        "call_request" => { "timezone" => "America/Los_Angeles" })
    end
    assert_response :ok
    assert_equal "+44 20 7946 0958", lead.reload.phone_raw

    post_details("submission_id" => submission_id, "contact" => { "phone_raw" => "12" })
    assert_response :bad_request
    assert_equal({ "contact.phone_raw" => "invalid" }, response.parsed_body["fields"])
  end
end
