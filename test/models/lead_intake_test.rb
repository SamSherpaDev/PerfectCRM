require "test_helper"

class LeadIntakeFieldsTest < ActiveSupport::TestCase
  test "reference is assigned on create in SH-XXXX form" do
    lead = Lead.create!(id: 6, name: "Anna Lindqvist", email: "anna@example.com", source: "website_form")
    assert_match(/\ASH-[A-Z2-9]{4}\z/, lead.reload.reference)
  end

  test "reference collisions do not prevent lead creation" do
    first = Lead.create!(name: "First visitor", reference: Lead.build_reference(823))
    second = Lead.create!(id: 823, name: "Second visitor")
    assert_not_equal first.reload.reference, second.reload.reference
    assert_match(/\ASH-[A-Z2-9]{4}\z/, second.reference)
    assert Lead.create!(name: "Next visitor").persisted?
  end

  test "build_reference is stable per id" do
    assert_equal Lead.build_reference(1), Lead.build_reference(1)
    assert_match(/\ASH-[A-Z2-9]{4}\z/, Lead.build_reference(42))
  end

  test "automation statuses exclude quoted, nudged, and won" do
    assert_equal %w[new chatting lost], Lead::AUTOMATION_STATUSES
    assert_not_includes Lead::AUTOMATION_STATUSES, "quoted"
    assert_not_includes Lead::AUTOMATION_STATUSES, "nudged"
    assert_not_includes Lead::STATUSES, "won"
  end

  test "intake columns persist" do
    lead = Lead.create!(
      name: "Anna Lindqvist", email: "anna@example.com", source: "google_ads",
      phone_raw: "+1 415 555 0134", phone_country: nil,
      trip_handle: "private-nepal-tour", trip_title: "Private Nepal tour",
      message: "Hello.", placement: "landing",
      travel_month: 4, travel_year: 2027, party_size: 2, budget_band: "4000_7000",
      spam_score: 25, received_at: Time.current,
      metadata: { "attribution" => { "gclid" => "x" } }
    )
    lead.reload
    assert_equal "+1 415 555 0134", lead.phone_raw
    assert_not_includes lead.attributes_before_type_cast["phone_raw"], "+1 415 555 0134"
    assert_equal "google_ads", lead.source
    assert_equal({ "attribution" => { "gclid" => "x" } }, lead.metadata)
  end
end

class SettingIntakeCredentialsTest < ActiveSupport::TestCase
  test "rotation changes keys and masks the secret" do
    settings = Setting.current
    key = settings.rotate_site_key!
    assert_match(/\Ash_site_/, key)
    secret = settings.rotate_relay_secret!
    assert_match(/\Ash_relay_/, secret)
    assert_equal "••••#{secret.last(4)}", settings.masked_relay_secret
    assert_not_includes settings.masked_relay_secret, secret[0..-5]
  end

  test "ensure_intake_credentials fills blanks once" do
    settings = Setting.current
    settings.update_columns(site_key: nil, relay_secret: nil)
    settings.ensure_intake_credentials!
    settings.reload
    assert settings.site_key.present?
    assert settings.relay_secret.present?
  end

  test "one configured webhook enables delivery" do
    settings = Setting.current
    settings.lead_webhook_url = "https://n8n.example.com/a"
    assert settings.valid?
    assert settings.webhooks_enabled?
    settings.lead_webhook_url = nil
    assert_not settings.webhooks_enabled?
  end
end
