require "test_helper"

# Verdict contract (docs/leads-intake.md): Panda AI scores through relay
# auth only, and may move leads between New, Chatting and Lost — nothing else.
class ApiV1LeadsVerdictsTest < ActionDispatch::IntegrationTest
  setup do
    @settings = Setting.current
    @settings.update!(lead_webhooks: [])
    @settings.rotate_site_key!
    @relay_secret = @settings.rotate_relay_secret!
    @lead = Lead.create!(name: "Anna Lindqvist", email: "anna@example.com", source: "google_ads", status: "new")
  end

  def post_verdict(lead_id, body, headers: {})
    raw = body.is_a?(String) ? body : JSON.generate(body)
    defaults = { "CONTENT_TYPE" => "application/json" }
    if headers.key?("X-Sherpa-Signature")
      defaults.merge!(headers)
    elsif !headers.delete(:unsigned)
      timestamp = Time.current.to_i
      digest = OpenSSL::HMAC.hexdigest("SHA256", @relay_secret, "#{timestamp}.#{raw}")
      sig = "t=#{timestamp},v1=#{digest}"
      sig += ",kid=#{headers.delete(:kid)}" if headers.key?(:kid)
      defaults["X-Sherpa-Signature"] = sig
      defaults.merge!(headers)
    end
    post "/api/v1/leads/#{lead_id}/verdict", params: raw, headers: defaults
  end

  test "a verdict scores and moves new to chatting with an automation event" do
    post_verdict @lead.id,
      { "fit_score" => 82, "fit_band" => "strong", "fit_reason" => "Honeymoon, flexible dates", "status" => "chatting" },
      headers: { kid: "panda-ai" }
    assert_response :ok
    json = response.parsed_body
    assert_equal @lead.reload.reference, json["reference"]
    assert_equal "chatting", json["status"]
    assert_equal 82, json["fit_score"]

    @lead.reload
    assert_equal "strong", @lead.fit_band
    assert_equal "Honeymoon, flexible dates", @lead.fit_reason
    event = @lead.activity_events.order(:id).last
    assert_equal "automation", event.kind
    assert_match(/Panda-ai/i, event.summary)
    assert_equal "panda-ai", event.metadata["caller"]
    assert_equal "new", event.metadata["from_status"]
    assert_equal "chatting", event.metadata["to_status"]
  end

  test "a score-only verdict keeps the stage" do
    post_verdict @lead.id, { "fit_score" => 34, "fit_band" => "weak" }
    assert_response :ok
    assert_equal "new", @lead.reload.status
    assert_equal "weak", @lead.fit_band
  end

  test "quoted is rejected" do
    post_verdict @lead.id, { "status" => "quoted" }
    assert_response :unprocessable_entity
    assert_equal "invalid", response.parsed_body["fields"]["status"]
    assert_equal "new", @lead.reload.status
  end

  test "won is rejected" do
    post_verdict @lead.id, { "status" => "won" }
    assert_response :unprocessable_entity
    assert_equal "new", @lead.reload.status
  end

  test "nudged is rejected" do
    post_verdict @lead.id, { "status" => "nudged" }
    assert_response :unprocessable_entity
  end

  test "lost is allowed" do
    post_verdict @lead.id, { "status" => "lost" }
    assert_response :ok
    assert_equal "lost", @lead.reload.status
  end

  test "out-of-range score and unknown band are rejected" do
    post_verdict @lead.id, { "fit_score" => 101, "fit_band" => "superb" }
    assert_response :unprocessable_entity
    assert_equal "invalid", response.parsed_body["fields"]["fit_score"]
    assert_equal "invalid", response.parsed_body["fields"]["fit_band"]
  end

  test "browser mode cannot reach the verdict endpoint" do
    post "/api/v1/leads/#{@lead.id}/verdict",
      params: JSON.generate({ "fit_score" => 80 }),
      headers: {
        "CONTENT_TYPE" => "application/json",
        "Origin" => "https://www.sherpaholidays.com",
        "X-Sherpa-Site-Key" => @settings.site_key
      }
    assert_response :unauthorized
  end

  test "stale relay timestamp is 401" do
    raw = JSON.generate({ "fit_score" => 80 })
    timestamp = 10.minutes.ago.to_i
    digest = OpenSSL::HMAC.hexdigest("SHA256", @relay_secret, "#{timestamp}.#{raw}")
    post "/api/v1/leads/#{@lead.id}/verdict", params: raw,
      headers: { "CONTENT_TYPE" => "application/json", "X-Sherpa-Signature" => "t=#{timestamp},v1=#{digest}" }
    assert_response :unauthorized
  end

  test "unknown lead is 404" do
    post_verdict 999_999, { "fit_score" => 80 }
    assert_response :not_found
  end

  test "a converted lead is rejected" do
    @lead.convert_to_client!
    post_verdict @lead.id, { "status" => "lost" }
    assert_response :unprocessable_entity
  end
end
