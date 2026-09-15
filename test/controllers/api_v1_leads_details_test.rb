require "test_helper"

# Details follow-up contract (docs/leads-intake.md, intake-spec.md section 2).
class ApiV1LeadsDetailsTest < ActionDispatch::IntegrationTest
  ORIGIN = "https://www.sherpaholidays.com"

  setup do
    @settings = Setting.current
    @settings.update!(lead_webhook_url: nil)
    @settings.rotate_site_key!
    @relay_secret = @settings.rotate_relay_secret!
    @site_key = @settings.site_key
    @submission_id = SecureRandom.uuid
    @lead = Lead.create!(
      name: "Anna Lindqvist", email: "anna@example.com", source: "website_form",
      external_ref: "website_form:#{@submission_id}", received_at: Time.current
    )
  end

  def details_body(overrides = {})
    {
      "schema" => "sherpa.inquiry.details.v1",
      "submission_id" => @submission_id,
      "trip" => { "month" => 4, "year" => 2027, "timing_unknown" => false, "budget_band" => "4000_7000" },
      "party" => { "size" => 2 }
    }.deep_merge(overrides)
  end

  def post_details(body, headers: {})
    post "/api/v1/leads/intake/details", params: body.is_a?(String) ? body : JSON.generate(body),
      headers: { "CONTENT_TYPE" => "application/json", "Origin" => ORIGIN, "X-Sherpa-Site-Key" => @site_key }.merge(headers)
  end

  test "valid details update only the provided fields and append a note" do
    assert_enqueued_with(job: LeadNotificationJob) do
      assert_no_enqueued_jobs only: LeadIntakeEmailJob do
        post_details details_body
      end
    end
    assert_response :ok
    assert_equal @lead.reload.reference, response.parsed_body["reference"]
    @lead.reload
    assert_equal 4, @lead.travel_month
    assert_equal 2027, @lead.travel_year
    assert_equal false, @lead.timing_unknown
    assert_equal "4000_7000", @lead.budget_band
    assert_equal 2, @lead.party_size
    assert_equal "Anna Lindqvist", @lead.name
    note = @lead.notes.order(:id).last
    assert_match(/Details added by the visitor at/, note.body)
  end

  test "partial details leave the rest alone" do
    post_details details_body
    assert_response :ok
    @lead.update!(budget_band: "under_2000")
    post_details({ "schema" => "sherpa.inquiry.details.v1", "submission_id" => @submission_id, "party" => { "size" => 3 } })
    assert_response :ok
    @lead.reload
    assert_equal 3, @lead.party_size
    assert_equal "under_2000", @lead.budget_band
  end

  test "the same body twice is one update and one note" do
    post_details details_body
    assert_response :ok
    assert_no_difference("Note.count") do
      post_details details_body
    end
    assert_response :ok
  end

  test "unknown submission id is 404" do
    post_details details_body("submission_id" => SecureRandom.uuid)
    assert_response :not_found
    assert_equal({ "error" => "not_found" }, response.parsed_body)
  end

  test "a lead older than 24 hours is 410" do
    @lead.update_columns(received_at: 25.hours.ago, created_at: 25.hours.ago)
    post_details details_body
    assert_response :gone
    assert_equal({ "error" => "expired" }, response.parsed_body)
  end

  test "out-of-range values map to their fields" do
    post_details details_body("trip" => { "month" => 13 }, "party" => { "size" => 99 })
    assert_response :bad_request
    assert_equal "validation", response.parsed_body["error"]
    assert_equal "invalid", response.parsed_body["fields"]["trip.month"]
    assert_equal "invalid", response.parsed_body["fields"]["party.size"]
  end

  test "unknown budget band maps to its field" do
    post_details details_body("trip" => { "budget_band" => "millions" })
    assert_response :bad_request
    assert_equal "invalid", response.parsed_body["fields"]["trip.budget_band"]
  end

  test "wrong schema is a 400 bad_request" do
    post_details details_body("schema" => "sherpa.inquiry.v2")
    assert_response :bad_request
  end

  test "bad site key is 403 and bad relay signature is 401" do
    post_details details_body, headers: { "X-Sherpa-Site-Key" => "nope" }
    assert_response :forbidden

    raw = JSON.generate(details_body)
    post "/api/v1/leads/intake/details", params: raw,
      headers: { "CONTENT_TYPE" => "application/json", "X-Sherpa-Signature" => "t=1,v1=nope" }
    assert_response :unauthorized
  end

  test "relay mode works without an origin" do
    raw = JSON.generate(details_body)
    timestamp = Time.current.to_i
    digest = OpenSSL::HMAC.hexdigest("SHA256", @relay_secret, "#{timestamp}.#{raw}")
    post "/api/v1/leads/intake/details", params: raw,
      headers: { "CONTENT_TYPE" => "application/json", "X-Sherpa-Signature" => "t=#{timestamp},v1=#{digest}" }
    assert_response :ok
  end
  test "replay recovers details notification after queue failure" do
    LeadNotificationJob.stub(:perform_later, ->(*) { raise "queue unavailable" }) do
      post_details details_body
      assert_response :ok
    end
    assert_equal [ "lead.details_added" ], @lead.lead_notifications.pluck(:event)
    assert_no_difference([ "Note.count", "LeadNotification.count" ]) do
      assert_enqueued_with(job: LeadNotificationJob) { post_details details_body }
    end
    assert_response :ok
  end

  test "outbox failure rolls back details and note" do
    LeadNotification.stub(:new, ->(*) { raise "outbox unavailable" }) do
      assert_no_difference("Note.count") do
        assert_raises(RuntimeError) { post_details details_body }
      end
    end
    assert_nil @lead.reload.travel_month
  end

  test "conversion before lock rejects stale details without writing" do
    stale = Lead.find(@lead.id)
    @lead.convert_to_client!
    Lead.stub(:find_by, stale) do
      assert_no_difference([ "Note.count", "LeadNotification.count" ]) do
        post_details details_body
      end
    end
    assert_response :unprocessable_entity
    assert_equal "converted", response.parsed_body["error"]
    assert_nil @lead.reload.travel_month
  end

  test "model validation failure returns a structured response" do
    @lead.update_column(:name, "")
    assert_no_difference([ "Note.count", "LeadNotification.count" ]) do
      post_details details_body
    end
    assert_response :unprocessable_entity
    assert_equal "validation", response.parsed_body["error"]
    assert_equal "invalid", response.parsed_body["fields"]["name"]
    assert_nil @lead.reload.travel_month
  end
end
