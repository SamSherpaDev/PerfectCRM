require "test_helper"
require_relative "../support/outbound_origins_test_helper"
require_relative "../support/google_sign_in_test_helper"

class SettingsAutomationsTest < ActionDispatch::IntegrationTest
  include OutboundOriginsTestHelper
  include GoogleSignInTestHelper

  setup do
    sign_in
    Setting.current.update!(lead_webhook_url: nil)
  end

  test "edit shows the automations card with site key, first reply link, and the log" do
    template = Template.create!(name: "Welcome", purpose: :first_reply, subject: "Hi", body: "Hello")
    get edit_settings_path
    assert_response :success
    assert_select "h2", text: "Automations"
    assert_select "p", text: /Website inquiries, automatic first replies, and the itinerary email/
    assert_select "input[name='setting[lead_webhook_url]']", count: 0
    assert_select "form[action=?]", rotate_site_key_settings_path
    assert_select "form[action=?]", rotate_relay_secret_settings_path, count: 0
    assert_select "a[href=?]", edit_template_path(template), text: "Edit First reply template"
  end

  test "first reply kill switch persists without moving its enable time" do
    enabled_at = Setting.current.auto_first_reply_enabled_at
    get edit_settings_path
    assert Setting.current.auto_first_reply_enabled?
    assert_select "input[type='checkbox'][name='setting[auto_first_reply_enabled]'][checked]"
    patch settings_path, params: { setting: { auto_first_reply_enabled: "0" } }
    assert_redirected_to edit_settings_path
    assert_not Setting.current.reload.auto_first_reply_enabled?
    patch settings_path, params: { setting: { auto_first_reply_enabled: "1" } }
    assert Setting.current.reload.auto_first_reply_enabled?
    assert_equal enabled_at, Setting.current.auto_first_reply_enabled_at
  end

  test "the itinerary email ships off and its switch stamps each switch-on" do
    get edit_settings_path
    assert_select "input[type='checkbox'][name='setting[itinerary_email_enabled]']:not([checked])"
    assert_select "a[href=?]", settings_itinerary_email_path, text: "Read the itinerary email"
    assert_not Setting.current.itinerary_email_enabled?
    assert_nil Setting.current.itinerary_email_enabled_at

    freeze_time do
      patch settings_path, params: { setting: { auto_first_reply_enabled: "1", itinerary_email_enabled: "1" } }
      assert_redirected_to edit_settings_path
      assert Setting.current.reload.itinerary_email_enabled?
      assert_equal Time.current, Setting.current.itinerary_email_enabled_at
    end
    first_reply_at = Setting.current.auto_first_reply_enabled_at
    travel 1.hour
    patch settings_path, params: { setting: { auto_first_reply_enabled: "1", itinerary_email_enabled: "1" } }
    assert_in_delta 1.hour.ago, Setting.current.reload.itinerary_email_enabled_at, 1.second
    patch settings_path, params: { setting: { auto_first_reply_enabled: "1", itinerary_email_enabled: "0" } }
    assert_not Setting.current.reload.itinerary_email_enabled?
    patch settings_path, params: { setting: { auto_first_reply_enabled: "1", itinerary_email_enabled: "1" } }
    assert_in_delta Time.current, Setting.current.reload.itinerary_email_enabled_at, 1.second
    assert Setting.current.auto_first_reply_enabled?
    assert_equal first_reply_at, Setting.current.auto_first_reply_enabled_at
  end

  test "the trip quiz email ships off and its switch stamps each switch-on" do
    get edit_settings_path
    assert_select "input[type='checkbox'][name='setting[trip_quiz_email_enabled]']:not([checked])"
    assert_select "a[href=?]", settings_trip_quiz_email_path, text: "Read the trip quiz email"
    assert_not Setting.current.trip_quiz_email_enabled?
    assert_nil Setting.current.trip_quiz_email_enabled_at

    freeze_time do
      patch settings_path, params: { setting: { auto_first_reply_enabled: "1", trip_quiz_email_enabled: "1" } }
      assert_redirected_to edit_settings_path
      assert Setting.current.reload.trip_quiz_email_enabled?
      assert_equal Time.current, Setting.current.trip_quiz_email_enabled_at
    end
    travel 1.hour
    patch settings_path, params: { setting: { auto_first_reply_enabled: "1", trip_quiz_email_enabled: "0" } }
    assert_not Setting.current.reload.trip_quiz_email_enabled?
    patch settings_path, params: { setting: { auto_first_reply_enabled: "1", trip_quiz_email_enabled: "1" } }
    assert_in_delta Time.current, Setting.current.reload.trip_quiz_email_enabled_at, 1.second
  end

  test "saving one webhook URL persists it" do
    patch settings_path, params: { setting: { lead_webhook_url: "https://n8n.example.com/hook" } }
    assert_redirected_to edit_settings_path
    assert_equal "https://n8n.example.com/hook", Setting.current.reload.lead_webhook_url
  end

  test "invalid or multiple webhook URLs are rejected" do
    [ "ftp://nope.example/hook", "https://n8n.example.com/a\nhttps://n8n.example.com/b" ].each do |url|
      patch settings_path, params: { setting: { lead_webhook_url: url } }
      assert_redirected_to edit_settings_path
      assert flash[:alert].present?
      assert_nil Setting.current.reload.lead_webhook_url
    end
  end

  test "rotating the site key changes it" do
    before = Setting.current.ensure_intake_credentials!.site_key
    post rotate_site_key_settings_path
    assert_redirected_to edit_settings_path
    assert_not_equal before, Setting.current.reload.site_key
  end

  test "rotating the relay secret changes it while keeping it hidden from Settings UI" do
    before = Setting.current.ensure_intake_credentials!.relay_secret
    post rotate_relay_secret_settings_path
    assert_redirected_to edit_settings_path
    follow_redirect!
    assert_response :success
    fresh = Setting.current.reload.relay_secret
    assert_not_equal before, fresh
    assert_not_includes response.body, fresh
  end

  test "automation events and deliveries appear in the log" do
    lead = Lead.create!(name: "Anna Lindqvist", email: "anna@example.com", source: "website_form")
    lead.activity_events.create!(kind: "automation", summary: "Panda AI scored this lead",
      occurred_at: Time.current, metadata: { "caller" => "panda-ai" })
    LeadWebhookDelivery.create!(lead: lead, event: "lead.created",
      url: "https://n8n.example.com/hook", status: "delivered", attempts: 1, http_status: 200)
    get edit_settings_path
    assert_response :success
    assert_select "p", text: /Panda AI scored this lead/
    assert_select "p", text: /lead\.created to/
  end

  test "lead pages show no Automations heading; automations live in Settings" do
    Setting.current.update!(lead_webhook_url: "https://n8n.example.com/hook")
    lead = Lead.create!(name: "Website visitor", source: "website_form", received_at: Time.current)
    LeadWebhookDelivery.create!(lead: lead, event: "lead.created", url: Setting.current.lead_webhook_url)
    get leads_path
    assert_response :success
    assert_select "h2", text: "Automations", count: 0
    get lead_path(lead)
    assert_response :success
    assert_select "h2", text: "Automations", count: 0
    get edit_settings_path
    assert_response :success
    assert_select "h2", text: "Automations"
  end

  test "lead page folds the inquiry into details facts and the oldest timeline stone" do
    lead = Lead.create!(
      name: "Anna Lindqvist", email: "anna@example.com", source: "website_form",
      trip_title: "Private Nepal tour", message: "Two of us.", placement: "landing",
      party_size: 2, travel_month: 4, travel_year: 2027
    )
    get lead_path(lead)
    assert_response :success
    assert_select "h2", { text: "Inquiry", count: 0 }
    assert_select "dd", text: /Private Nepal tour/
    assert_select "dd", text: /#{lead.reference}/
    assert_select "#inquiry", text: /Two of us/
  end
  test "unknown timing takes precedence over earlier dates" do
    lead = Lead.create!(name: "Visitor", travel_month: 4, travel_year: 2027, timing_unknown: true)
    get lead_path(lead)
    assert_response :success
    assert_select "dd", text: /Timing unknown/
    assert_select "dd", text: /April|2027/, count: 0
  end
end
