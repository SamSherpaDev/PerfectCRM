require "test_helper"

# Itinerary designer contract (docs/leads-intake.md, "Itinerary designer"):
# the itinerary_designer placement, its stored trip, the details call
# request, and the automatic itinerary email behind its Settings switch.
class ApiV1LeadsItineraryIntakeTest < ActionDispatch::IntegrationTest
  include ActionMailer::TestHelper

  ORIGIN = "https://www.sherpaholidays.com"
  ITINERARY = {
    "base_trip" => { "handle" => "pokhara-mountain-views-tour", "title" => "Pokhara Mountain Views Tour" },
    "stops" => [
      { "title" => "Kathmandu", "day_from" => 1 },
      { "title" => "Pokhara and Sarangkot", "day_from" => 2, "day_to" => 3 },
      { "title" => "Back to Kathmandu and home", "day_from" => 4 }
    ],
    "interests" => [ "Mountain views, easy walking" ],
    "pace" => "easy",
    "length_days" => 7,
    "season" => "not_sure",
    "group_size" => 3,
    "email_list" => true,
    "share_url" => "https://www.sherpaholidays.com/pages/design-your-trip#p=easy&s=ktm1,sara,home&n=3&w=unsure",
    "source" => "instagram_bio"
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
      "placement" => "itinerary_designer",
      "contact" => { "name" => "Anna Lindqvist", "email" => "anna@gmail.com" },
      "message" => "Itinerary: Kathmandu, Pokhara and Sarangkot, back to Kathmandu.",
      "consent" => { "contact" => true, "contact_at" => "2026-11-02T18:06:40Z", "text_version" => "2026-11-designer-v1" },
      "page" => { "url" => "https://www.sherpaholidays.com/pages/design-your-trip" },
      "timing" => { "started_at" => "2026-11-02T18:02:58Z", "submitted_at" => "2026-11-02T18:06:41Z" },
      "honeypot" => "",
      "client" => { "version" => "itinerary-designer@1.0.0" },
      "itinerary" => ITINERARY.deep_dup
    }.deep_merge(overrides)
  end

  def post_intake(body)
    post "/api/v1/leads/intake", params: JSON.generate(body),
      headers: { "CONTENT_TYPE" => "application/json", "Origin" => ORIGIN, "X-Sherpa-Site-Key" => @site_key }
  end

  def post_details(body)
    post "/api/v1/leads/intake/details", params: JSON.generate(body.merge("schema" => "sherpa.inquiry.details.v1")),
      headers: { "CONTENT_TYPE" => "application/json", "Origin" => ORIGIN, "X-Sherpa-Site-Key" => @site_key }
  end

  test "an itinerary designer inquiry stores its trip on the lead" do
    post_intake intake_body
    assert_response :accepted
    lead = Lead.last
    assert_equal "itinerary_designer", lead.placement
    assert_equal "pokhara-mountain-views-tour", lead.trip_handle
    assert_equal "Pokhara Mountain Views Tour", lead.trip_title
    assert_equal 3, lead.party_size
    assert lead.timing_unknown
    assert_equal "Itinerary: Kathmandu, Pokhara and Sarangkot, back to Kathmandu.", lead.message
    itinerary = lead.itinerary
    assert_equal 3, itinerary["stops"].size
    assert_equal({ "title" => "Pokhara and Sarangkot", "day_from" => 2, "day_to" => 3 }, itinerary["stops"][1])
    assert_equal true, itinerary["email_list"]
    assert_equal "itinerary-designer@1.0.0", itinerary["client_version"]
    assert_equal "instagram_bio", itinerary["source"]
    assert_equal ITINERARY["share_url"], itinerary["share_url"]
  end

  test "a bad itinerary answers 400 naming the field and stores nothing" do
    assert_no_difference("Lead.count") do
      post_intake intake_body("itinerary" => { "pace" => "sprint" })
    end
    assert_response :bad_request
    assert_equal({ "error" => "validation", "fields" => { "itinerary.pace" => "invalid" } }, response.parsed_body)
  end

  test "landing posts with a plain-text itinerary keep working and ignore an itinerary key" do
    post_intake intake_body("placement" => "landing", "itinerary" => { "pace" => "sprint" })
    assert_response :accepted
    lead = Lead.last
    assert_equal "landing", lead.placement
    assert_nil lead.itinerary
    assert_nil lead.party_size
    assert_equal "Itinerary: Kathmandu, Pokhara and Sarangkot, back to Kathmandu.", lead.message
    assert_not lead.lead_notifications.exists?(event: "itinerary_email")
  end

  test "a caller-supplied _itinerary is never stored, whatever the placement" do
    forged = { "stops" => [ { "title" => "Claim your refund at evil . com", "day_from" => 1 } ],
      "share_url" => "javascript:alert(document.cookie)", "group_size" => 9, "season" => "not_sure" }
    @settings.update!(itinerary_email_enabled: true)
    [ "landing", nil, "itinerary_designer" ].each_with_index do |placement, index|
      body = intake_body("contact" => { "email" => "visitor#{index}@gmail.com" }).except("itinerary").merge("_itinerary" => forged)
      body = placement ? body.merge("placement" => placement) : body.except("placement")
      post_intake body
      assert_response :accepted
      lead = Lead.last
      assert_nil lead.itinerary, placement.inspect
      assert_not lead.metadata.key?("itinerary")
      assert_nil lead.party_size
      assert_not lead.timing_unknown
      assert_not lead.lead_notifications.exists?(event: "itinerary_email")
    end
  end

  test "a designer post without an itinerary is still an inquiry" do
    post_intake intake_body.except("itinerary")
    assert_response :accepted
    assert_equal "itinerary_designer", Lead.last.placement
    assert_nil Lead.last.itinerary
  end

  test "the same trip sent twice merges, a changed trip stays its own inquiry" do
    post_intake intake_body
    assert_response :accepted
    assert_no_difference("Lead.count") { post_intake intake_body }
    assert_response :ok
    assert_difference("Lead.count", 1) do
      post_intake intake_body("itinerary" => { "length_days" => 14 })
    end
    assert_response :accepted
  end

  test "the itinerary email waits a minute and only when switched on" do
    post_intake intake_body
    assert_not Lead.last.lead_notifications.exists?(event: "itinerary_email")

    @settings.update!(itinerary_email_enabled: true)
    freeze_time do
      post_intake intake_body("contact" => { "email" => "bea@gmail.com" })
      notification = Lead.last.lead_notifications.find_by!(event: "itinerary_email")
      assert_equal 1.minute.from_now, notification.available_at
    end
  end

  test "switched on, the visitor gets one itinerary email and the first reply stands aside" do
    @settings.update!(itinerary_email_enabled: true, auto_first_reply_enabled: true, auto_first_reply_enabled_at: 1.hour.ago)
    Template.create!(name: "First reply", purpose: :first_reply, channel: "email", body: "Hi {{first_name}}, let's arrange a call.")
    travel 1.second
    post_intake intake_body
    lead = Lead.last
    itinerary_notification = lead.lead_notifications.find_by!(event: "itinerary_email")
    first_reply_notification = lead.lead_notifications.find_by!(event: "auto_first_reply")

    travel 1.minute
    assert_difference("Message.outbound.count", 1) { LeadNotificationJob.perform_now(itinerary_notification.id) }
    message = lead.itinerary_email.message
    assert_equal "Your Nepal itinerary", message.subject
    assert_equal [ "anna@gmail.com" ], message.to_list
    assert_emails(1) { perform_enqueued_jobs(only: OutboundDeliveryJob) }

    travel 1.minute
    assert_no_difference("Message.outbound.count") { LeadNotificationJob.perform_now(first_reply_notification.id) }
    assert_includes lead.activity_events.where(kind: "automation").pluck(:summary), "Automatic first reply: skipped (already contacted)"
  end

  test "details take a call window once and note it" do
    post_intake intake_body
    submission_id = Lead.last.external_ref.delete_prefix("website_form:")
    post_details("submission_id" => submission_id, "call_request" => { "window" => "weekday_evening", "timezone" => "Europe/Stockholm" })
    assert_response :ok
    lead = Lead.last
    assert_equal "weekday_evening", lead.call_request["window"]
    assert_equal "Europe/Stockholm", lead.call_request["timezone"]
    assert lead.call_request["requested_at"].present?
    assert_match(/Free call requested: Weekday evenings \(Europe\/Stockholm\)\./, lead.notes.last.body)

    assert_no_difference("Note.count") do
      post_details("submission_id" => submission_id, "call_request" => { "window" => "weekday_evening", "timezone" => "Europe/Stockholm" })
    end
    assert_response :ok
  end

  test "details still refuse a call request without a window" do
    post_intake(intake_body)
    submission_id = Lead.last.external_ref.delete_prefix("website_form:")
    post_details("submission_id" => submission_id, "call_request" => { "timezone" => "Europe/Stockholm" })
    assert_response :bad_request
    assert_equal({ "call_request.window" => "invalid" }, response.parsed_body["fields"])
    assert_nil Lead.last.call_request
  end

  test "details refuse a bad call window" do
    post_intake intake_body
    submission_id = Lead.last.external_ref.delete_prefix("website_form:")
    post_details("submission_id" => submission_id, "call_request" => { "window" => "midnight" })
    assert_response :bad_request
    assert_equal({ "call_request.window" => "invalid" }, response.parsed_body["fields"])
    assert_nil Lead.last.call_request
  end
end
