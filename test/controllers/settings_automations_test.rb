require "test_helper"
require_relative "../support/google_sign_in_test_helper"

class SettingsAutomationsTest < ActionDispatch::IntegrationTest
  include GoogleSignInTestHelper

  setup do
    sign_in
    Setting.current.update!(intake_copy_to: "info@sherpaholidays.com", lead_webhooks: [])
  end

  test "edit shows the automations card with keys, rules, and the log" do
    get edit_settings_path
    assert_response :success
    assert_select "h2", text: "Automations"
    assert_select "p", text: /Automations may create leads/
    assert_select "p", text: /Quoted, Nudged, conversion to client/
    assert_select "input[name='setting[intake_copy_to]']"
    assert_select "textarea[name='setting[lead_webhooks_text]']"
    assert_select "form[action=?]", rotate_site_key_settings_path
    assert_select "form[action=?]", rotate_relay_secret_settings_path
  end

  test "saving copy-to and webhook urls persists them" do
    patch settings_path, params: {
      setting: {
        intake_copy_to: "captain@example.com",
        lead_webhooks_text: "https://n8n.example.com/hook-a\nhttps://n8n.example.com/hook-b\n"
      }
    }
    assert_redirected_to edit_settings_path
    settings = Setting.current.reload
    assert_equal "captain@example.com", settings.intake_copy_to
    assert_equal [ "https://n8n.example.com/hook-a", "https://n8n.example.com/hook-b" ],
      settings.lead_webhook_urls
  end

  test "non-http webhook urls are rejected" do
    patch settings_path, params: {
      setting: { intake_copy_to: "info@sherpaholidays.com", lead_webhooks_text: "ftp://nope.example/hook" }
    }
    assert_redirected_to edit_settings_path
    assert_match(/http/, flash[:alert].to_s)
    assert_empty Setting.current.reload.lead_webhook_urls
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

  test "leads page shows the automations strip" do
    get leads_path
    assert_response :success
    assert_select "h2", text: "Automations"
    assert_select "p", text: "Website form"
    assert_select "p", text: "Panda AI"
    assert_select "p", text: "n8n webhooks"
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
end
