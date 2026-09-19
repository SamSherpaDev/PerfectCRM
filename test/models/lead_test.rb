require "test_helper"

class LeadTest < ActiveSupport::TestCase
  test "normalizes email and external ref" do
    lead = Lead.create!(name: "Ad", source: "google_ads", email: " AD@Example.com ", external_ref: "  n8n-1 ")
    assert_equal "ad@example.com", lead.reload.email
    assert_equal "n8n-1", lead.reload.external_ref
  end

  test "validates source, status, and fit" do
    lead = Lead.new(name: "X", source: "smoke", status: "new")
    assert_not lead.valid?
    lead.source = "manual"
    lead.status = "won"
    assert_not lead.valid?
    lead.status = "new"
    lead.fit_score = 120
    assert_not lead.valid?
    lead.fit_score = 82
    lead.fit_band = "strong"
    assert lead.valid?
  end

  test "external ref is unique for idempotency" do
    Lead.create!(name: "One", source: "manual", external_ref: "n8n-1")
    assert_not Lead.new(name: "Two", source: "manual", external_ref: "n8n-1").valid?
  end

  test "phone is encrypted at rest" do
    lead = Lead.create!(name: "Ad", source: "manual", phone: "+1-415-555-0134")
    raw = Lead.connection.select_value(
      Lead.sanitize_sql([ "SELECT phone FROM leads WHERE id = ?", lead.id ])
    )
    assert_not_includes raw.to_s, "415-555"
    assert_equal "+1-415-555-0134", lead.reload.phone
  end

  test "conversion copies everything and freezes the lead" do
    org = Organization.create!(name: "Referrer", kind: "advisor")
    lead = Lead.create!(
      name: "Ad Lead", email: "ad@example.com", source: "google_ads",
      campaign_name: "Everest", referred_by_organization: org, tag_list: "everest"
    )
    lead.people.create!(name: "Maya", role: "spouse", email: "maya@example.com")
    Note.create!(notable: lead, body: "Clicked ad")
    ActivityEvent.create!(subject: lead, kind: "automation", summary: "Scored by Panda AI", occurred_at: Time.current)

    client = lead.convert_to_client!
    assert_equal "Ad Lead", client.name
    assert_equal "google_ads", client.source
    assert_equal "Everest", client.campaign_name
    assert_equal [ "everest" ], client.tags.order(:name).pluck(:name)
    assert_equal [ "Maya" ], client.people.order(:id).pluck(:name)
    assert_equal 1, client.notes.where("body LIKE ?", "%Clicked ad%").count
    assert client.activity_events.where(kind: "conversion").exists?
    assert lead.reload.converted?
    assert_equal client.id, lead.converted_client_id
    assert_not_nil lead.converted_at
  end

  test "conversion cannot run twice and cannot reverse" do
    lead = Lead.create!(name: "Ad", source: "manual")
    lead.convert_to_client!
    assert_raises(ActiveRecord::RecordInvalid) { lead.convert_to_client! }
    assert_not lead.update(converted_client_id: nil)
    assert_includes lead.errors[:converted_client], "cannot be removed once set"
    assert_not lead.update(status: "chatting")
    assert_includes lead.errors[:base], "Converted leads stay read-only"
  end

  test "automation events are allowed on the timeline" do
    lead = Lead.create!(name: "Ad", source: "manual")
    event = ActivityEvent.create!(subject: lead, kind: "automation", summary: "n8n import", occurred_at: Time.current)
    assert_equal "automation", event.reload.kind
  end

  test "lead search matches campaign and people" do
    first = Lead.create!(name: "Tashi", source: "google_ads", campaign_name: "Everest Spring")
    second = Lead.create!(name: "Maya", source: "manual")
    second.people.create!(name: "Pasang", email: "pasang@example.net")
    assert_includes Lead.search("everest"), first
    assert_not_includes Lead.search("everest"), second
    assert_includes Lead.search("pasang@example"), second
  end
  test "conversion preserves every supplied source" do
    Lead::SOURCES.each do |source|
      client = Lead.create!(name: "Attribution", source: source, campaign_name: "Spring").convert_to_client!
      assert_equal source, client.source
      assert_equal "Spring", client.campaign_name
    end
  end

  test "archiving scopes split on archived_at and leave working lists" do
    lead = Lead.create!(name: "Archie", source: "manual", status: "chatting")
    assert_includes Lead.active, lead
    lead.archive!
    assert lead.reload.archived?
    assert_includes Lead.archived, lead
    assert_not_includes Lead.active, lead
    assert_not_includes Lead.open, lead
    assert_not_includes Lead.by_status("chatting"), lead
    lead.unarchive!
    assert_not lead.reload.archived?
    assert_includes Lead.by_status("chatting"), lead
  end

  test "archived leads leave the lost and stale working sets" do
    lost = Lead.create!(name: "Lostie", source: "manual", status: "lost", lost_reason: "no_reply")
    assert_includes Lead.lost, lost
    stale = Lead.create!(name: "Stale", source: "manual", status: "new")
    stale.update_columns(last_touch_at: 30.days.ago, last_activity_at: 30.days.ago, updated_at: 30.days.ago)
    assert_includes Lead.stale, stale
    lost.archive!
    stale.archive!
    assert_not_includes Lead.lost, lost.reload
    assert_not_includes Lead.stale, stale.reload
  end

  test "converted leads refuse archive" do
    lead = Lead.create!(name: "Won", source: "manual")
    lead.convert_to_client!
    error = assert_raises(ActiveRecord::RecordInvalid) { lead.archive! }
    assert_match(/read-only/, error.record.errors.full_messages.to_sentence)
    assert_not lead.reload.archived?
  end

  test "an archived email does not block a new open lead" do
    old = Lead.create!(name: "Old", source: "manual", email: "reuse@example.com")
    old.archive!
    fresh = Lead.new(name: "New", source: "manual", email: "reuse@example.com")
    assert fresh.valid?
  end
end
