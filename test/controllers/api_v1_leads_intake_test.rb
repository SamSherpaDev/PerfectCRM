require "test_helper"
require_relative "../support/request_logs_test_helper"

# Public intake contract (docs/leads-intake.md, intake-spec.md section 2):
# every status code and mode, in validation order.
class ApiV1LeadsIntakeTest < ActionDispatch::IntegrationTest
  include RequestLogsTestHelper
  ORIGIN = "https://www.sherpaholidays.com"

  setup do
    @settings = Setting.current
    @settings.update!(lead_webhook_url: nil)
    @settings.rotate_site_key!
    @relay_secret = @settings.rotate_relay_secret!
    @site_key = @settings.site_key
  end

  # -- helpers -----------------------------------------------------------

  def intake_body(overrides = {})
    {
      "schema" => "sherpa.inquiry.v2",
      "submission_id" => SecureRandom.uuid,
      "placement" => "landing",
      "contact" => { "name" => "Anna Lindqvist", "email" => "anna@example.com", "phone_raw" => "+1 415 555 0134" },
      "trip" => { "handle" => "private-nepal-tour", "title" => "Private Nepal tour" },
      "message" => "Two of us, first time in Nepal, thinking spring.",
      "consent" => { "contact" => true, "contact_at" => "2026-09-14T18:06:40Z", "text_version" => "2026-09-consent-v2" },
      "attribution" => { "utm_campaign" => "private-nepal-us-2027" },
      "page" => { "url" => "https://www.sherpaholidays.com/pages/private-nepal-tours" },
      "timing" => { "started_at" => "2026-09-14T18:05:58Z", "submitted_at" => "2026-09-14T18:06:41Z" },
      "honeypot" => "",
      "client" => { "version" => "inquiry-form@1.0.0" }
    }.deep_merge(overrides)
  end

  def post_intake(body, headers: {})
    post "/api/v1/leads/intake", params: body.is_a?(String) ? body : JSON.generate(body),
      headers: { "CONTENT_TYPE" => "application/json", "Origin" => ORIGIN, "X-Sherpa-Site-Key" => @site_key }.merge(headers)
  end

  def relay_headers(body, at: Time.current, kid: nil)
    timestamp = at.to_i
    digest = OpenSSL::HMAC.hexdigest("SHA256", @relay_secret, "#{timestamp}.#{body}")
    sig = "t=#{timestamp},v1=#{digest}"
    sig += ",kid=#{kid}" if kid
    { "X-Sherpa-Signature" => sig }
  end

  def with_memory_cache(&block)
    Rails.stub(:cache, ActiveSupport::Cache::MemoryStore.new, &block)
  end

  # -- CORS preflight ----------------------------------------------------

  test "preflight answers with the allowlist and a 24h cache" do
    options "/api/v1/leads/intake", headers: { "Origin" => ORIGIN }
    assert_response :no_content
    assert_equal ORIGIN, response.headers["Access-Control-Allow-Origin"]
    assert_equal "POST, OPTIONS", response.headers["Access-Control-Allow-Methods"]
    assert_includes response.headers["Access-Control-Allow-Headers"], "X-Sherpa-Site-Key"
    assert_equal "86400", response.headers["Access-Control-Max-Age"]
  end

  test "preflight from elsewhere carries no CORS headers" do
    options "/api/v1/leads/intake", headers: { "Origin" => "https://evil.example" }
    assert_response :no_content
    assert_nil response.headers["Access-Control-Allow-Origin"]
  end

  test "details preflight answers too" do
    options "/api/v1/leads/intake/details", headers: { "Origin" => "https://sherpaholidays.com" }
    assert_response :no_content
    assert_equal "https://sherpaholidays.com", response.headers["Access-Control-Allow-Origin"]
  end

  # -- happy path ----------------------------------------------------------

  test "intake request logs retain operational status without identity or nested free text" do
    logs = capture_request_logs do
      post_intake intake_body("contact" => { "name" => "PrivateSyntheticName", "email" => "private@example.com" },
        "message" => "PrivateSyntheticMessage", "attribution" => { "utm_campaign" => "PrivateSyntheticCampaign" })
      assert_response :accepted
    end
    assert_includes logs, "Started POST"
    assert_includes logs, "Completed 202"
    assert_includes logs, "[FILTERED]"
    %w[PrivateSyntheticName private@example.com PrivateSyntheticMessage PrivateSyntheticCampaign].each do |value|
      assert_not_includes logs, value
    end
    assert_equal "PrivateSyntheticMessage", Lead.last.message
  end

  test "valid browser request creates one lead and answers 202" do
    assert_enqueued_jobs 3, only: LeadNotificationJob do
      post_intake intake_body
    end
    assert_response :accepted
    json = response.parsed_body
    assert json["reference"].match?(/\ASH-[A-Z2-9]{4}\z/)
    assert_equal true, json["conversion"]
    assert_equal 1, Lead.where("external_ref LIKE 'website_form:%'").count

    lead = Lead.last
    assert_equal json["id"], lead.id
    assert_equal json["reference"], lead.reference
    assert_equal "Anna Lindqvist", lead.name
    assert_equal "anna@example.com", lead.email
    assert_equal "+14155550134", lead.phone
    assert_equal "+1 415 555 0134", lead.phone_raw
    assert_equal "private-nepal-tour", lead.trip_handle
    assert_equal "Private Nepal tour", lead.trip_title
    assert_equal "private-nepal-us-2027", lead.campaign_name
    assert_equal "landing", lead.placement
    assert_equal "website_form", lead.source
    assert_equal "new", lead.status
    assert_equal 0, lead.spam_score
    assert lead.received_at.present?
    assert_equal "2026-09-consent-v2", lead.consent_text_version
    assert_equal "https://www.sherpaholidays.com/pages/private-nepal-tours",
      lead.metadata["page"]["url"]
    assert_equal "inquiry-form@1.0.0", lead.metadata["client"]["version"]
    assert lead.metadata["ip_hash"].present?
  end

  test "direct website inquiry without a non-direct visit gets one first reply two minutes later" do
    Setting.current.update!(auto_first_reply_enabled_at: 1.hour.ago, sender_name: "Sam", email_signature: "Sam")
    Template.create!(name: "First reply", purpose: :first_reply, body: "Hi {{first_name}}, let's arrange a call.", channel: "email")
    travel_to Time.current.change(usec: 0) do
      # The live storefront emits null when this visitor has no sh_non_direct
      # cookie. Direct visits still carry their observed first and last touch.
      touch = { "observed_at" => Time.current.iso8601, "landing_url" => "https://www.sherpaholidays.com/pages/contact" }
      body = intake_body("contact" => { "email" => "synthetic@gmail.com" }, "acquisition" => {
        "permission" => { "state" => "allowed", "measurement" => true, "sharing" => true, "opted_out" => false,
          "observed_at" => Time.current.iso8601 },
        "first_touch" => touch, "last_touch" => touch, "last_non_direct_touch" => nil
      })
      post_intake body
      assert_response :accepted
      lead = Lead.last
      assert_equal "new", lead.status
      assert_equal "direct", lead.metadata.dig("acquisition", "last_touch", "source")
      assert_nil lead.metadata.dig("acquisition", "last_non_direct_touch")
      notification = lead.lead_notifications.find_by!(event: "auto_first_reply")
      assert_equal 2.minutes.from_now, notification.available_at
      assert_enqueued_with(job: LeadNotificationJob, args: [ notification.id ], at: 2.minutes.from_now)
      assert_no_difference("Message.outbound.count") { LeadNotificationJob.perform_now(notification.id) }
      travel 2.minutes
      assert_difference("Message.outbound.count", 1) { LeadNotificationJob.perform_now(notification.id) }
      assert_no_difference([ "Message.outbound.count", "LeadNotification.count" ]) do
        post_intake body
        LeadNotificationJob.perform_now(notification.id)
      end
      assert_response :ok
    end
  end

  # Same contact payload the BK-app inquiry extension sends after a visitor
  # fills the full form. Only the spelling of the optional phone changes.
  {
    "ten digits" => "4155550134",
    "eleven digits" => "14155550134",
    "spaces" => "415 555 0134",
    "dashes" => "415-555-0134",
    "dots" => "415.555.0134",
    "parentheses" => "(415) 555-0134",
    "plus US" => "+1 415 555 0134",
    "international" => "+44 20 7946 0958"
  }.each do |format, raw|
    test "visitor phone survives intake and conversion: #{format}" do
      post_intake intake_body("contact" => { "phone_raw" => raw })
      assert_response :accepted
      lead = Lead.find(response.parsed_body.fetch("id"))
      expected = format == "international" ? "+442079460958" : "+14155550134"
      assert_equal expected, lead.phone
      assert_equal raw, lead.phone_raw
      assert_equal expected, lead.display_phone
      assert_nil lead.country # A parsing default is not evidence of residence.
      client = lead.convert_to_client!
      assert_equal expected, client.phone
      assert_equal raw, client.phone_raw
      assert_equal expected, client.display_phone
      assert_not_includes client.attributes_before_type_cast["phone_raw"], raw
    end
  end

  test "unparseable visitor phone is retained through conversion" do
    raw = "  ask for Alex at reception  "
    post_intake intake_body("contact" => { "phone_raw" => raw })
    assert_response :accepted
    lead = Lead.find(response.parsed_body.fetch("id"))
    assert_nil lead.phone
    assert_equal raw, lead.phone_raw
    assert_equal raw, lead.display_phone
    client = lead.convert_to_client!
    assert_nil client.phone
    assert_equal raw, client.display_phone
  end

  test "full form intake and both optional followups retain every collected answer" do
    observed = 1.hour.ago.iso8601
    touch = { "observed_at" => observed, "utm_source" => "google", "utm_medium" => "cpc", "utm_campaign" => "synthetic-nepal", "gclid" => "synthetic-click" }
    acquisition = {
      "permission" => { "state" => "allowed", "measurement" => true, "sharing" => true, "observed_at" => observed },
      "first_touch" => touch, "last_touch" => touch, "last_non_direct_touch" => touch,
      "submission_page" => { "url" => "https://www.sherpaholidays.com/pages/contact" }
    }
    body = intake_body("contact" => { "phone_raw" => "415-555-0134" }, "acquisition" => acquisition,
      "page" => { "template" => "page.contact", "locale" => "en-US" })
    post_intake body
    assert_response :accepted
    lead = Lead.find(response.parsed_body.fetch("id"))
    assert_equal body.dig("contact", "name"), lead.name
    assert_equal body.dig("contact", "email"), lead.email
    assert_equal "+14155550134", lead.phone
    assert_equal body.dig("trip", "handle"), lead.trip_handle
    assert_equal body.dig("trip", "title"), lead.trip_title
    assert_equal body["message"], lead.message
    assert_equal Time.iso8601(body.dig("consent", "contact_at")), lead.consent_contact_at
    assert_equal body.dig("consent", "text_version"), lead.consent_text_version
    assert_equal "page.contact", lead.metadata.dig("page", "template")
    assert_equal "en-US", lead.metadata.dig("page", "locale")
    %w[first_touch last_touch last_non_direct_touch].each do |key|
      assert_equal "synthetic-click", lead.metadata.dig("acquisition", key, "gclid")
      assert_equal "synthetic-nepal", lead.metadata.dig("acquisition", key, "utm_campaign")
      assert_equal Time.iso8601(observed), Time.iso8601(lead.metadata.dig("acquisition", key, "observed_at"))
    end
    assert_equal true, lead.metadata.dig("acquisition", "permission", "measurement")
    assert_equal "https://www.sherpaholidays.com/pages/contact", lead.metadata.dig("acquisition", "submission_page", "landing_url")
    headers = { "CONTENT_TYPE" => "application/json", "Origin" => ORIGIN, "X-Sherpa-Site-Key" => @site_key }
    post "/api/v1/leads/intake/details", headers: headers, params: JSON.generate({
      schema: "sherpa.inquiry.details.v1", submission_id: body["submission_id"],
      trip: { month: 4, year: 2027, timing_unknown: false, budget_band: "4000_7000" }, party: { size: 3 }
    })
    assert_response :ok
    post "/api/v1/leads/intake/details", headers: headers, params: JSON.generate({
      schema: "sherpa.inquiry.details.v1", submission_id: body["submission_id"], acquisition: acquisition,
      source_answer: { code: "personal_referral", detail: "Synthetic friend", question_version: "how-heard-v1" }
    })
    assert_response :ok
    lead.reload
    assert_equal [ 4, 2027, false, 3, "4000_7000" ], [ lead.travel_month, lead.travel_year, lead.timing_unknown, lead.party_size, lead.budget_band ]
    assert_equal "personal_referral", lead.reported_source_code
    assert_equal "Synthetic friend", lead.reported_source_detail
    assert_equal "answered", lead.source_answer_state
  end

  test "compact form payload does not invent uncollected contact or trip details" do
    body = intake_body("placement" => "trip_page", "contact" => { "phone_raw" => "" })
    post_intake body
    assert_response :accepted
    lead = Lead.find(response.parsed_body.fetch("id"))
    assert_nil lead.phone
    assert_nil lead.country
    assert_nil lead.party_size
    assert_nil lead.travel_month
    assert_nil lead.travel_year
    assert_nil lead.budget_band
    assert_equal "trip_page", lead.placement
    post "/api/v1/leads/intake/details", params: JSON.generate({ schema: "sherpa.inquiry.details.v1",
      submission_id: body["submission_id"], source_answer: { code: "search", question_version: "how-heard-v1" } }),
      headers: { "CONTENT_TYPE" => "application/json", "Origin" => ORIGIN, "X-Sherpa-Site-Key" => @site_key }
    assert_response :ok
    assert_equal "search", lead.reload.reported_source_code
    assert_nil lead.party_size
  end

  test "country supplied by an API caller is retained without guessing a US phone" do
    post_intake intake_body("contact" => { "phone_raw" => "020 7946 0958", "country" => "GB" })
    assert_response :accepted
    assert_equal "GB", Lead.last.country
    assert_nil Lead.last.phone
    assert_equal "020 7946 0958", Lead.last.display_phone
  end

  test "bare domain origin is accepted" do
    post_intake intake_body, headers: { "Origin" => "https://sherpaholidays.com" }
    assert_response :accepted
    assert_equal "https://sherpaholidays.com", response.headers["Access-Control-Allow-Origin"]
  end

  test "a valid referral code is stored with the lead" do
    post_intake intake_body("attribution" => { "referral_code" => "KQ7X2D" })
    assert_response :accepted
    assert_equal "KQ7X2D", Lead.last.referral_code
    assert_equal "KQ7X2D", Lead.last.metadata["attribution"]["referral_code"]
  end

  test "a missing referral code stores nothing" do
    post_intake intake_body
    assert_response :accepted
    assert_nil Lead.last.referral_code
  end

  test "an invalid referral code is ignored, never rejected" do
    post_intake intake_body("attribution" => { "referral_code" => "REF-1" })
    assert_response :accepted
    assert_nil Lead.last.referral_code
  end

  test "a lowercase referral code is normalized" do
    post_intake intake_body("attribution" => { "referral_code" => "kq7x2d" })
    assert_response :accepted
    assert_equal "KQ7X2D", Lead.last.referral_code
  end

  # -- source derivation table ----------------------------------------------

  {
    "gclid present" => [ { "gclid" => "Cj0K" }, "google_ads" ],
    "gbraid present" => [ { "gbraid" => "x" }, "google_ads" ],
    "wbraid present" => [ { "wbraid" => "x" }, "google_ads" ],
    "google paid search" => [ { "utm_source" => "google", "utm_medium" => "cpc" }, "google_ads" ],
    "google paid alternate medium" => [ { "utm_source" => "Google", "utm_medium" => "paid" }, "google_ads" ],
    "google organic" => [ { "utm_source" => "google", "utm_medium" => "organic" }, "website_form" ],
    "facebook paid" => [ { "utm_source" => "facebook", "utm_medium" => "cpc" }, "meta_ads" ],
    "instagram paid" => [ { "utm_source" => "instagram", "utm_medium" => "ppc" }, "meta_ads" ],
    "meta paid" => [ { "utm_source" => "meta", "utm_medium" => "paid" }, "meta_ads" ],
    "facebook organic" => [ { "utm_source" => "facebook", "utm_medium" => "social" }, "website_form" ],
    "trade show booth" => [ { "utm_source" => "bay-area-travel-show", "utm_medium" => "event" }, "trade_show" ],
    "trade show medium any case" => [ { "utm_medium" => " Event " }, "trade_show" ],
    "no attribution" => [ {}, "website_form" ]
  }.each do |name, (attribution, expected)|
    test "source derivation: #{name} is #{expected}" do
      post_intake intake_body("attribution" => attribution)
      assert_response :accepted
      assert_equal expected, Lead.last.source
    end
  end

  test "business test inquiries never queue ad conversions" do
    body = intake_body("attribution" => { "gclid" => "Cj0K" })
    body["contact"]["email"] = Mail.mailbox_address
    assert_no_enqueued_jobs only: AdConversions::LeadJob do
      post_intake body
    end
    assert_response :accepted
    assert_empty AdConversions.record!(Lead.last)
  end

  test "a new permission-allowed lead queues its ad conversion job" do
    assert_enqueued_with(job: AdConversions::LeadJob) do
      post_intake intake_body("acquisition" => {
        "permission" => { "state" => "allowed", "measurement" => true, "sharing" => true },
        "last_touch" => { "observed_at" => Time.current.iso8601, "gclid" => "Cj0K" }
      })
    end
    assert_response :accepted
    assert_equal "website_form", Lead.last.capture_channel
    assert_equal "google_ads", Lead.last.source
  end

  test "legacy intake remains accepted but missing advertising permission withholds exports" do
    assert_no_enqueued_jobs only: AdConversions::LeadJob do
      post_intake intake_body("attribution" => { "gclid" => "Cj0K" })
    end
    assert_response :accepted
    assert_equal "Cj0K", Lead.last.metadata.dig("attribution", "gclid")
    assert_equal "google_ads", Lead.last.source
  end

  test "denied fbclid landing is scrubbed and new snapshots are bounded" do
    post_intake intake_body("acquisition" => {
      "permission" => { "state" => "denied" },
      "first_touch" => { "fbclid" => "secret-click", "landing_url" => "https://www.sherpaholidays.com/?fbclid=secret-click" }
    }, "page" => { "url" => "https://www.sherpaholidays.com/?fbclid=secret-click&email=private%40example.com" },
      "attribution" => { "fbclid" => "secret-click", "landing_url" => "https://www.sherpaholidays.com/?fbclid=secret-click" })
    assert_response :accepted
    assert_nil Lead.last.metadata.dig("page", "url")
    assert_equal({ "unknown_reason" => "declined_permission" }, Lead.last.metadata.dig("acquisition", "first_touch"))
    assert_nil Lead.last.metadata.dig("attribution", "fbclid")
    assert_no_difference("Lead.count") do
      post_intake intake_body("acquisition" => { "permission" => { "state" => "anything" } })
    end
    assert_response :bad_request
  end

  # -- replay -----------------------------------------------------------------

  test "replay of the same submission id returns 200 with the original reference and conversion true" do
    body = intake_body
    post_intake body
    assert_response :accepted
    reference = response.parsed_body["reference"]
    assert_equal true, response.parsed_body["conversion"]

    assert_no_difference("Lead.count") do
      post_intake body
    end
    assert_response :ok
    assert_equal reference, response.parsed_body["reference"]
    assert_equal true, response.parsed_body["conversion"]
  end

  test "replay of an auto-archived submission returns 200 with conversion false" do
    honeypot_body = intake_body("honeypot" => "http://spam.example", "message" => "Autofilled by my browser")
    post_intake honeypot_body
    assert_response :accepted
    honeypot_ref = response.parsed_body["reference"]
    assert_equal false, response.parsed_body["conversion"]

    assert_no_difference("Lead.count") do
      post_intake honeypot_body
    end
    assert_response :ok
    assert_equal honeypot_ref, response.parsed_body["reference"]
    assert_equal false, response.parsed_body["conversion"]

    fast_body = intake_body(
      "contact" => { "name" => "Speed Bot", "email" => "speedbot@example.com" },
      "timing" => { "started_at" => "2026-09-14T18:06:40Z", "submitted_at" => "2026-09-14T18:06:41Z" }
    )
    post_intake fast_body
    assert_response :accepted
    fast_ref = response.parsed_body["reference"]
    assert_equal false, response.parsed_body["conversion"]

    assert_no_difference("Lead.count") do
      post_intake fast_body
    end
    assert_response :ok
    assert_equal fast_ref, response.parsed_body["reference"]
    assert_equal false, response.parsed_body["conversion"]
  end

  # -- honeypot -----------------------------------------------------------------

  test "filled honeypot is saved to Archived as spam with its reason, no notifications, and a counted catch" do
    assert_difference("Lead.count", 1) do
      assert_difference("Leads.honeypot_catches_count", 1) do
        post_intake intake_body("honeypot" => "http://spam.example", "message" => "Autofilled by my browser")
      end
    end
    assert_response :accepted
    assert_equal false, response.parsed_body["conversion"]
    lead = Lead.find(response.parsed_body["id"])
    assert_equal lead.reference, response.parsed_body["reference"]
    assert_equal [ "Anna Lindqvist", "anna@example.com", "Autofilled by my browser" ], [ lead.name, lead.email, lead.message ]
    assert lead.archived?
    assert lead.spam_marked_at.present?
    assert lead.suspected_spam?
    assert_equal "Hidden field filled", lead.spam_reason
    assert_empty lead.lead_notifications
    assert_includes lead.activity_events.find_by(kind: "spam_review").summary, "Hidden field filled"
  end

  # -- auth -----------------------------------------------------------------------

  test "unknown site key is 403" do
    post_intake intake_body, headers: { "X-Sherpa-Site-Key" => "nope" }
    assert_response :forbidden
    assert_equal({ "error" => "forbidden" }, response.parsed_body)
  end

  test "bad origin is 403" do
    post_intake intake_body, headers: { "Origin" => "https://evil.example" }
    assert_response :forbidden
  end

  test "missing origin is 403" do
    post "/api/v1/leads/intake", params: JSON.generate(intake_body),
      headers: { "CONTENT_TYPE" => "application/json", "X-Sherpa-Site-Key" => @site_key }
    assert_response :forbidden
  end

  # -- relay mode ------------------------------------------------------------------

  test "relay mode skips the origin check and records the caller" do
    raw = JSON.generate(intake_body)
    post "/api/v1/leads/intake", params: raw,
      headers: { "CONTENT_TYPE" => "application/json" }.merge(relay_headers(raw, kid: "n8n"))
    assert_response :accepted
    assert_equal "n8n", Lead.last.metadata["attribution"]["relay"]
  end

  test "relay mode with a bad signature is 401" do
    raw = JSON.generate(intake_body)
    post "/api/v1/leads/intake", params: raw,
      headers: { "CONTENT_TYPE" => "application/json", "X-Sherpa-Signature" => "t=#{Time.current.to_i},v1=deadbeef" }
    assert_response :unauthorized
  end

  test "relay mode with a stale timestamp is 401" do
    raw = JSON.generate(intake_body)
    post "/api/v1/leads/intake", params: raw,
      headers: { "CONTENT_TYPE" => "application/json" }.merge(relay_headers(raw, at: 10.minutes.ago))
    assert_response :unauthorized
  end

  # -- validation order ---------------------------------------------------------------

  test "malformed json is a 400 bad_request" do
    post_intake "{oops"
    assert_response :bad_request
    assert_equal({ "error" => "bad_request" }, response.parsed_body)
  end

  test "wrong schema is a 400 bad_request" do
    post_intake intake_body("schema" => "sherpa.inquiry.v1")
    assert_response :bad_request
    assert_equal({ "error" => "bad_request" }, response.parsed_body)
  end

  test "oversize body is a 400 bad_request" do
    post_intake intake_body("message" => "x" * (33 * 1024))
    assert_response :bad_request
    assert_equal({ "error" => "bad_request" }, response.parsed_body)
  end

  test "missing name maps to its field" do
    post_intake intake_body("contact" => { "name" => "A", "email" => "anna@example.com" })
    assert_response :bad_request
    assert_equal "validation", response.parsed_body["error"]
    assert_equal "invalid", response.parsed_body["fields"]["contact.name"]
  end

  test "bad email shape maps to its field" do
    post_intake intake_body("contact" => { "name" => "Anna Lindqvist", "email" => "not-an-email" })
    assert_response :bad_request
    assert_equal "invalid", response.parsed_body["fields"]["contact.email"]
  end

  test "email domain without records is invalid" do
    post_intake intake_body("contact" => { "name" => "Anna Lindqvist", "email" => "anna@anything.invalid" })
    assert_response :bad_request
    assert_equal "invalid", response.parsed_body["fields"]["contact.email"]
  end

  test "missing consent is invalid" do
    post_intake intake_body("consent" => { "contact" => false })
    assert_response :bad_request
    assert_equal "invalid", response.parsed_body["fields"]["consent.contact"]
  end

  # -- rate limits ----------------------------------------------------------------------

  test "the 11th request from one ip in 10 minutes gets 429 with retry-after" do
    with_memory_cache do
      10.times do |n|
        post_intake intake_body("contact" => { "name" => "Visitor #{n}", "email" => "visitor#{n}@example.com" })
        assert_response :accepted
      end
      post_intake intake_body("contact" => { "name" => "Visitor X", "email" => "visitorx@example.com" })
      assert_response :too_many_requests
      assert_equal "rate_limited", response.parsed_body["error"]
      assert response.headers["Retry-After"].to_i.positive?
    end
  end

  test "the 4th request for one email in an hour gets 429" do
    with_memory_cache do
      # Each distinct inquiry opens its own lead, and every attempt
      # still counts toward the email window.
      messages = [
        "Two of us, first time in Nepal, thinking spring.",
        "Family of four looking for a private cultural tour in Bhutan next October.",
        "Solo trekker asking about Upper Mustang permits and autumn departure dates."
      ]
      messages.each do |msg|
        post_intake intake_body("message" => msg)
        assert_response :accepted
      end
      post_intake intake_body("message" => "Fourth inquiry within the hour about helicopter charter options.")
      assert_response :too_many_requests
    end
  end

  # -- duplicate filter -----------------------------------------------------------------

  test "same email with the same normalized message within 24h merges into existing lead as timeline entry" do
    first_body = intake_body("contact" => { "name" => "Anna Lindqvist", "email" => "Anna@Example.com", "phone_raw" => "" })
    post_intake first_body
    assert_response :accepted
    first = response.parsed_body
    assert_equal true, first["conversion"]
    lead = Lead.find(first["id"])

    duplicate_submission_id = SecureRandom.uuid
    assert_no_difference([ "Lead.count", "LeadNotification.count", "AdConversion.count" ]) do
      assert_no_enqueued_jobs do
        post_intake intake_body(
          "submission_id" => duplicate_submission_id,
          "contact" => { "name" => "Anna Lindqvist", "email" => "  anna@example.com ", "phone_raw" => "+1 415 555 0134" },
          "message" => "Two of us, first time in Nepal, thinking spring!"
        )
      end
    end
    assert_response :ok
    second = response.parsed_body
    assert_equal first["id"], second["id"]
    assert_equal first["reference"], second["reference"]
    assert_equal false, second["conversion"]

    lead.reload
    assert_equal "+14155550134", lead.phone
    assert_includes lead.metadata["merged_submission_ids"], duplicate_submission_id
    event = lead.activity_events.find_by(kind: "duplicate_inquiry")
    assert event.present?
    assert_includes event.summary, "Duplicate website inquiry merged"
    assert_equal duplicate_submission_id, event.metadata["submission_id"]

    # Step 2 details submitted under the merged duplicate submission_id still attach to the existing lead.
    post "/api/v1/leads/intake/details",
      params: JSON.generate({ schema: "sherpa.inquiry.details.v1", submission_id: duplicate_submission_id, party: { size: 4 } }),
      headers: { "CONTENT_TYPE" => "application/json", "Origin" => ORIGIN, "X-Sherpa-Site-Key" => @site_key }
    assert_response :ok
    assert_equal 4, lead.reload.party_size
  end

  test "a second inquiry from the same email with a different message or trip opens its own lead" do
    post_intake intake_body
    assert_response :accepted
    first = response.parsed_body
    assert_equal true, first["conversion"]

    assert_difference("Lead.count", 1) do
      post_intake intake_body("message" => "Actually we are also interested in a Bhutan cultural tour in autumn for four people.")
    end
    assert_response :accepted
    second = response.parsed_body
    assert_not_equal first["id"], second["id"]
    assert_not_equal first["reference"], second["reference"]
    assert_equal true, second["conversion"]

    assert_difference("Lead.count", 1) do
      post_intake intake_body("trip" => { "handle" => "everest-base-camp-trek", "title" => "Everest Base Camp Trek" })
    end
    assert_response :accepted
    assert_equal true, response.parsed_body["conversion"]
    assert_equal 3, Lead.where(email: "anna@example.com").count
  end

  test "a near-identical but different message from the same email opens its own lead" do
    post_intake intake_body(
      "trip" => {},
      "message" => "Hi, we are two adults interested in the Everest Base Camp trek in April 2027, please send prices and availability"
    )
    assert_response :accepted
    first = response.parsed_body

    assert_difference("Lead.count", 1) do
      post_intake intake_body(
        "trip" => {},
        "message" => "Hi, we are two adults interested in the Annapurna Base Camp trek in October 2027, please send prices and availability"
      )
    end
    assert_response :accepted
    assert_not_equal first["id"], response.parsed_body["id"]
  end

  test "a duplicate of an inquiry already converted to a client opens a new lead instead of failing" do
    post_intake intake_body
    assert_response :accepted
    converted = Lead.find(response.parsed_body["id"])
    converted.convert_to_client!

    assert_difference("Lead.count", 1) do
      post_intake intake_body
    end
    assert_response :accepted
    assert_not_equal converted.id, response.parsed_body["id"]
  end

  test "replaying a merged duplicate submission id returns the original lead even after the merge window" do
    post_intake intake_body
    assert_response :accepted
    original = response.parsed_body
    assert_equal true, original["conversion"]
    duplicate_body = intake_body
    post_intake duplicate_body
    assert_response :ok
    assert_equal original["id"], response.parsed_body["id"]
    assert_equal false, response.parsed_body["conversion"]

    travel 25.hours do
      assert_no_difference([ "Lead.count", "LeadNotification.count" ]) do
        post_intake duplicate_body
      end
      assert_response :ok
      assert_equal original["id"], response.parsed_body["id"]
      assert_equal original["reference"], response.parsed_body["reference"]
      assert_equal false, response.parsed_body["conversion"]
    end
  end

  test "only an auto-archived resubmission merges into an archived spam lead; flag-only and clean ones open a lead in New" do
    fast = { "started_at" => "2026-09-14T18:06:40Z", "submitted_at" => "2026-09-14T18:06:41Z" }
    contact = { "name" => "Pemba", "email" => "pemba@example.com" }
    post_intake intake_body("contact" => contact, "timing" => fast)
    assert_response :accepted
    assert_equal false, response.parsed_body["conversion"]
    archived = Lead.find(response.parsed_body["id"])
    assert archived.archived?

    assert_no_difference("Lead.count") do
      post_intake intake_body("contact" => contact, "timing" => fast)
    end
    assert_response :ok
    assert_equal archived.id, response.parsed_body["id"]
    assert_equal false, response.parsed_body["conversion"]

    assert_difference("Lead.count", 1) do
      post_intake intake_body("contact" => contact)
    end
    assert_response :accepted
    assert_equal true, response.parsed_body["conversion"]
    retry_lead = Lead.find(response.parsed_body["id"])
    assert_not_equal archived.id, retry_lead.id
    assert_equal [ "name_matches_email" ], retry_lead.suspicion_hits
    assert_not retry_lead.archived?
  end

  test "same email and message after 24 hours opens a new inquiry" do
    post_intake intake_body
    assert_response :accepted
    assert_equal true, response.parsed_body["conversion"]

    travel 25.hours do
      assert_difference("Lead.count", 1) do
        post_intake intake_body
      end
      assert_response :accepted
      assert_equal true, response.parsed_body["conversion"]
    end
  end

  # -- suspicion scoring & high-confidence spam routing ---------------------------------

  test "a rushed submit under 3s is saved but archived and marked spam with its reason" do
    body = intake_body(
      "timing" => { "started_at" => "2026-09-14T18:06:40Z", "submitted_at" => "2026-09-14T18:06:41Z" }
    )
    post_intake body
    assert_response :accepted
    assert_equal false, response.parsed_body["conversion"]
    lead = Lead.last
    assert_equal 25, lead.spam_score
    assert lead.suspected_spam?
    assert lead.archived?
    assert lead.spam_marked_at.present?
    assert_includes lead.metadata["suspicion_hits"], "too_fast"
    assert_equal "Submitted under 3s", lead.spam_reason
    assert_empty lead.lead_notifications
    review = lead.activity_events.find_by(kind: "spam_review")
    assert review.present?
    assert_includes review.summary, "Submitted under 3s"
  end

  test "missing, invalid, or non-ISO timing is not a spam signal" do
    [
      intake_body.except("timing"),
      intake_body.merge("timing" => {}),
      intake_body("timing" => { "started_at" => "not-a-timestamp", "submitted_at" => "2026-09-14T18:06:41Z" }),
      intake_body("timing" => { "started_at" => "2026-09-14 18:05:58", "submitted_at" => "2026-09-14 18:06:41" })
    ].each_with_index do |body, idx|
      body = body.deep_merge("contact" => { "email" => "timing#{idx}@example.com" })
      post_intake body
      assert_response :accepted
      lead = Lead.last
      assert_equal 0, lead.spam_score
      assert_not lead.suspected_spam?
      assert_not lead.archived?
      assert lead.lead_notifications.exists?(event: "auto_first_reply")
    end
  end

  test "lower-confidence suspect with a single moderate signal stays in New and is flagged only" do
    body = intake_body(
      "contact" => { "name" => "Anna Lindqvist", "email" => "annalindqvist@example.com" }
    )
    post_intake body
    assert_response :accepted
    assert_equal true, response.parsed_body["conversion"]
    lead = Lead.last
    assert_equal 25, lead.spam_score
    assert lead.suspected_spam?
    assert_not lead.archived?
    assert_nil lead.spam_marked_at
    assert_equal [ "name_matches_email" ], lead.metadata["suspicion_hits"]
    assert_equal "Name matches email", lead.spam_reason
  end

  test "spam flags never reject: disposable domain and link-stuffing together still 202 and stay flag-only in New" do
    body = intake_body(
      "contact" => { "name" => "Cheap Deals", "email" => "x@mailinator.com" },
      "message" => "see http://a.example http://b.example http://c.example"
    )
    post_intake body
    assert_response :accepted
    assert_equal true, response.parsed_body["conversion"]
    lead = Lead.last
    assert_equal 50, lead.spam_score
    assert lead.suspected_spam?
    assert_not lead.archived?
    assert_nil lead.spam_marked_at
  end

  test "flagged lead email copy carries the check prefix" do
    body = intake_body(
      "contact" => { "name" => "Anna Lindqvist", "email" => "annalindqvist@example.com" }
    )
    post_intake body
    perform_enqueued_jobs only: LeadNotificationJob
    mail = ActionMailer::Base.deliveries.last
    assert_match(/\A\[check\] New inquiry from/, mail.subject)
  end

  test "end-to-end bot protection: real submission creates a lead and conversion while fast, honeypot, and duplicate submissions do not" do
    @settings.update!(
      meta_dataset_id: "123456789012345",
      meta_access_token: "EAAB-token",
      meta_terms_accepted: true,
      google_terms_accepted: true,
      auto_first_reply_enabled_at: 1.hour.ago
    )
    @settings.rotate_google_feed_password!

    observed = Time.current.iso8601
    ad_acquisition = {
      "permission" => { "state" => "allowed", "measurement" => true, "sharing" => true, "observed_at" => observed },
      "last_touch" => { "observed_at" => observed, "gclid" => "Cj0K-real", "fbclid" => "IwAR-real", "utm_source" => "google", "utm_medium" => "cpc" }
    }

    # 1. Real submission creates an active lead in New and records an ad conversion.
    real_body = intake_body(
      "contact" => { "name" => "Clara Jensen", "email" => "clara@gmail.com" },
      "acquisition" => ad_acquisition
    )
    assert_difference("Lead.count", 1) do
      assert_enqueued_with(job: AdConversions::LeadJob) do
        post_intake real_body
      end
    end
    assert_response :accepted
    assert_equal true, response.parsed_body["conversion"]
    real_lead = Lead.find(response.parsed_body["id"])
    assert_not real_lead.archived?
    assert_not real_lead.suspected_spam?
    assert real_lead.lead_notifications.exists?(event: "auto_first_reply")
    assert_difference("AdConversion.count", 1) do
      AdConversions.record!(real_lead)
    end

    # 2. Fast submission (< 3s) is saved to Archived as spam, gets no auto first reply, and records no ad conversion.
    fast_body = intake_body(
      "contact" => { "name" => "Automated Script", "email" => "bot-runner@gmail.com" },
      "timing" => { "started_at" => "2026-09-14T18:06:40Z", "submitted_at" => "2026-09-14T18:06:41Z" },
      "acquisition" => ad_acquisition
    )
    assert_difference("Lead.count", 1) do
      assert_no_enqueued_jobs only: AdConversions::LeadJob do
        post_intake fast_body
      end
    end
    assert_response :accepted
    assert_equal false, response.parsed_body["conversion"]
    fast_lead = Lead.find(response.parsed_body["id"])
    assert fast_lead.archived?
    assert fast_lead.spam_marked_at.present?
    assert_equal "Submitted under 3s", fast_lead.spam_reason
    assert_empty fast_lead.lead_notifications
    assert_no_difference("AdConversion.count") do
      assert_empty AdConversions.record!(fast_lead)
    end
    assert_not_includes AdConversions::GoogleFeed.rows.map(&:lead_id), fast_lead.id

    # 3. Honeypot submission is saved to Archived as spam with no notifications or ad conversion, and is counted as a catch.
    honeypot_body = intake_body(
      "contact" => { "name" => "Trap Bot", "email" => "trapbot@gmail.com" },
      "honeypot" => "https://bot.example",
      "acquisition" => ad_acquisition
    )
    assert_difference("Lead.count", 1) do
      assert_no_enqueued_jobs only: AdConversions::LeadJob do
        assert_difference("Leads.honeypot_catches_count", 1) do
          post_intake honeypot_body
        end
      end
    end
    assert_response :accepted
    assert_equal false, response.parsed_body["conversion"]
    honeypot_lead = Lead.find(response.parsed_body["id"])
    assert honeypot_lead.archived?
    assert honeypot_lead.spam_marked_at.present?
    assert_equal "Hidden field filled, Name matches email", honeypot_lead.spam_reason
    assert_empty honeypot_lead.lead_notifications
    assert_no_difference("AdConversion.count") do
      assert_empty AdConversions.record!(honeypot_lead)
    end
    assert_not_includes AdConversions::GoogleFeed.rows.map(&:lead_id), honeypot_lead.id

    # 4. Duplicate submission within 24h merges into the real lead without creating a second lead, notification, or conversion.
    duplicate_body = real_body.merge(
      "submission_id" => SecureRandom.uuid,
      "contact" => { "name" => "Clara Jensen", "email" => "CLARA@gmail.com" },
      "message" => "Two of us, first time in Nepal, thinking spring"
    )
    assert_no_difference([ "Lead.count", "AdConversion.count", "LeadNotification.count" ]) do
      assert_no_enqueued_jobs do
        post_intake duplicate_body
      end
    end
    assert_response :ok
    assert_equal real_lead.id, response.parsed_body["id"]
    assert_equal false, response.parsed_body["conversion"]
    assert_equal 1, real_lead.activity_events.where(kind: "duplicate_inquiry").count
  end
  test "malformed contact receives field validation errors" do
    [ "invalid", [] ].each do |contact|
      post_intake intake_body.merge("contact" => contact)
      assert_response :bad_request
      assert_equal "invalid", response.parsed_body["fields"]["contact.email"]
    end
  end

  test "malformed signature receives unauthorized" do
    post_intake intake_body, headers: { "X-Sherpa-Signature" => "invalid" }
    assert_response :unauthorized
  end

  test "replay recovers notification enqueue failure" do
    body = intake_body
    LeadNotificationJob.stub(:perform_later, ->(*) { raise "queue unavailable" }) do
      post_intake body
      assert_response :accepted
    end
    assert_equal %w[email_copy lead.created auto_first_reply], Lead.last.lead_notifications.order(:id).pluck(:event)
    assert_no_difference("LeadNotification.count") do
      assert_enqueued_jobs 3, only: LeadNotificationJob do
        post_intake body
        assert_response :ok
      end
    end
  end

  test "notification persistence failure rolls back the inquiry" do
    LeadNotification.stub(:new, ->(*) { raise "outbox unavailable" }) do
      assert_no_difference("Lead.count") do
        assert_raises(RuntimeError) { post_intake intake_body }
      end
    end
  end

  test "a replay missed by the lookup recovers from validation conflict" do
    body = intake_body
    post_intake body
    assert_response :accepted
    original = response.parsed_body
    lookup = Lead.method(:find_by)
    calls = 0
    Lead.stub(:find_by, ->(*args) { calls += 1; calls == 1 ? nil : lookup.call(*args) }) do
      assert_no_difference([ "Lead.count", "LeadNotification.count" ]) do
        assert_enqueued_jobs 3, only: LeadNotificationJob do
          post_intake body
        end
      end
    end
    assert_response :ok
    assert_equal original, response.parsed_body
  end

  test "a uniqueness conflict recovers the original submission and notifications" do
    body = intake_body
    post_intake body
    assert_response :accepted
    original = response.parsed_body
    lookup = Lead.method(:find_by)
    calls = 0
    conflicting = Lead.new
    def conflicting.save
      raise ActiveRecord::RecordNotUnique, "submission already exists"
    end
    Lead.stub(:find_by, ->(*args) { calls += 1; calls == 1 ? nil : lookup.call(*args) }) do
      Lead.stub(:new, conflicting) do
        assert_no_difference([ "Lead.count", "LeadNotification.count" ]) do
          assert_enqueued_jobs 3, only: LeadNotificationJob do
            post_intake body
          end
        end
      end
    end
    assert_response :ok
    assert_equal original, response.parsed_body
  end
end
