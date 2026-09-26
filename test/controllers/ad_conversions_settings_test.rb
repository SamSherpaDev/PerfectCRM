require "test_helper"
require_relative "../support/google_sign_in_test_helper"

class AdConversionsSettingsTest < ActionDispatch::IntegrationTest
  include GoogleSignInTestHelper

  setup do
    @settings = Setting.current
    @settings.update!(meta_dataset_id: nil, meta_access_token: nil, google_feed_password: nil)
  end

  def basic(username, password)
    { "Authorization" => ActionController::HttpAuthentication::Basic.encode_credentials(username, password) }
  end

  test "the feed stays closed until a password exists" do
    get google_conversions_feed_path, headers: basic("sherpaholidays", "")
    assert_response :not_found
  end

  test "the feed asks for the right credentials" do
    password = @settings.rotate_google_feed_password!
    get google_conversions_feed_path
    assert_response :unauthorized
    get google_conversions_feed_path, headers: basic("sherpaholidays", "wrong")
    assert_response :unauthorized
    get google_conversions_feed_path, headers: basic("someone", password)
    assert_response :unauthorized
  end

  test "Google pulls the CSV with the feed password and the pull is logged" do
    password = @settings.rotate_google_feed_password!
    lead = Lead.create!(name: "Anna Lindqvist", email: "anna@example.com", source: "google_ads",
      status: "chatting", fit_band: "strong", received_at: 1.day.ago,
      metadata: { "attribution" => { "gclid" => "Cj0K-click" } })
    Leads::Transition.call(lead, to: "chatting")
    lead.activity_events.create!(kind: "automation", summary: "AI verdict", occurred_at: Time.current,
      metadata: { "fit_band" => "strong" })
    AdConversions.record!(lead)

    get google_conversions_feed_path, headers: basic("sherpaholidays", password)
    assert_response :success
    assert_equal "text/csv", response.media_type
    assert_equal "no-store", response.headers["Cache-Control"]
    lines = response.body.lines
    assert_equal "Parameters:TimeZone=America/Los_Angeles\n", lines.first
    assert_match(/\ACj0K-click,.*,Qualified inquiry,/, lines[2])
    assert_equal 1, @settings.reload.google_feed_last_row_count
    assert @settings.google_feed_last_fetched_at.present?
  end

  test "the settings card shows both platforms off and the feed details" do
    sign_in
    get edit_settings_path
    assert_response :success
    assert_select "h2", text: "Ad conversions"
    assert_select "span.badge", text: "Meta off"
    assert_select "span.badge", text: "Google off"
    assert_select "p.mono", text: google_conversions_feed_url
    assert_select "input[name='setting[meta_dataset_id]']"
    assert_select "input[type=password][name='setting[meta_access_token]']"
  end

  test "saving Meta keeps the token encrypted and a blank token keeps the saved one" do
    sign_in
    patch ad_conversions_settings_path, params: { setting: {
      meta_dataset_id: " 123456789012345 ", meta_access_token: "EAAB-token", ad_booking_value_percent: "30"
    } }
    assert_redirected_to edit_settings_path(anchor: "ad-conversions-heading")
    @settings.reload
    assert @settings.meta_configured?
    assert_equal "123456789012345", @settings.meta_dataset_id
    assert_equal 30, @settings.ad_booking_value_percent
    raw = Setting.connection.select_value("SELECT meta_access_token FROM settings WHERE id = #{@settings.id}")
    assert_not_includes raw, "EAAB-token"

    patch ad_conversions_settings_path, params: { setting: { meta_dataset_id: "123456789012345", meta_access_token: "" } }
    assert_equal "EAAB-token", @settings.reload.meta_access_token

    get edit_settings_path
    assert_select "span.badge", text: "Meta on"
    assert_not_includes response.body, "EAAB-token"
  end

  test "a malformed dataset ID is rejected" do
    sign_in
    patch ad_conversions_settings_path, params: { setting: { meta_dataset_id: "pixel-abc" } }
    assert_response :unprocessable_entity
    assert_select "p.text-bad", text: /Meta dataset/
    assert_nil @settings.reload.meta_dataset_id
  end

  test "creating the feed password shows it once, then masked" do
    sign_in
    post rotate_google_feed_password_settings_path
    follow_redirect!
    password = @settings.reload.google_feed_password
    assert_select "p[role=status]", text: /#{password}/
    get edit_settings_path
    assert_not_includes response.body, password
    assert_select "span.badge", text: "Google on"
  end
end
