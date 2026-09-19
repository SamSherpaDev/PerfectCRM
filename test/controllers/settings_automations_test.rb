require "test_helper"
require_relative "../support/google_sign_in_test_helper"

class SettingsAutomationsTest < ActionDispatch::IntegrationTest
  include GoogleSignInTestHelper

  setup do
    sign_in
    Setting.current.update!(lead_webhook_url: nil)
  end

  test "edit shows the automations card with keys, rules, and the log" do
    get edit_settings_path
    assert_response :success
    assert_select "h2", text: "Automations"
    assert_select "p", text: /Automations may create leads/
    assert_select "p", text: /Quoted, Nudged, conversion to client/
    assert_select "input[name='setting[lead_webhook_url]']"
    assert_select "form[action=?]", rotate_site_key_settings_path
    assert_select "form[action=?]", rotate_relay_secret_settings_path
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

  test "rotating the relay secret shows it once, then masked" do
    post rotate_relay_secret_settings_path
    assert_redirected_to edit_settings_path
    follow_redirect!
    assert_response :success
    fresh = Setting.current.reload.relay_secret
    assert_includes response.body, fresh

    get edit_settings_path
    assert_response :success
    assert_not_includes response.body, fresh
    assert_includes response.body, Setting.current.masked_relay_secret
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

  test "lead page shows the inquiry section for website leads" do
    lead = Lead.create!(
      name: "Anna Lindqvist", email: "anna@example.com", source: "website_form",
      trip_title: "Private Nepal tour", message: "Two of us.", placement: "landing",
      party_size: 2, travel_month: 4, travel_year: 2027
    )
    get lead_path(lead)
    assert_response :success
    assert_select "h2", text: "Inquiry"
    assert_select "dd", text: /Private Nepal tour/
    assert_select "dd", text: /Two of us/
    assert_select "dd", text: /#{lead.reference}/
  end
  test "unknown timing takes precedence over earlier dates" do
    lead = Lead.create!(name: "Visitor", travel_month: 4, travel_year: 2027, timing_unknown: true)
    get lead_path(lead)
    assert_response :success
    assert_select "dd", text: /Timing unknown/
    assert_select "dd", text: /April|2027/, count: 0
  end
end
