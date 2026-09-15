require "test_helper"
require_relative "../../db/migrate/20260914211512_backfill_lead_last_touch"

class LeadMailTouchTest < ActiveSupport::TestCase
  test "ingestion advances contact time on new and linked threads without regressing on old mail" do
    lead = Lead.create!(name: "Mail traveler", email: "touch@example.com")
    lead.update_columns(last_touch_at: 10.days.ago, last_activity_at: 10.days.ago)
    first = 2.days.ago.change(usec: 0)
    result = ingest(lead, at: first, id: "first")
    assert_equal :stored, result[:status]
    assert_equal lead, result[:conversation].linkable
    assert_equal first, lead.reload.last_touch_at

    latest = 1.hour.ago.change(usec: 0)
    assert_equal :stored, ingest(lead, at: latest, id: "reply", outbound: true)[:status]
    assert_equal latest, lead.reload.last_touch_at
    activity = lead.last_activity_at
    assert_equal :stored, ingest(lead, at: 20.days.ago, id: "old")[:status]
    assert_equal latest, lead.reload.last_touch_at
    assert_operator lead.last_activity_at, :>=, activity
    assert_not lead.stale?

    stale_instance = Lead.find(lead.id)
    lead.record_touch!(at: Time.current)
    newest_touch = lead.reload.last_touch_at
    stale_instance.record_touch!(at: first)
    assert_equal newest_touch, lead.reload.last_touch_at
  end

  test "linking triage uses the latest message time and respects a newer note" do
    lead = Lead.create!(name: "Triage traveler")
    lead.update_columns(last_touch_at: 12.days.ago)
    conversation = Conversation.create!(subject: "Unfiled")
    latest = 2.days.ago.change(usec: 0)
    conversation.messages.create!(direction: "in", sent_at: latest)
    conversation.messages.create!(direction: "out", sent_at: 5.days.ago)
    conversation.update!(linkable: lead)
    assert_equal latest, lead.reload.last_touch_at
    assert_not lead.stale?

    noted = Lead.create!(name: "Recently noted")
    noted.notes.create!(body: "Heard back today")
    touch = noted.reload.last_touch_at
    conversation.update!(linkable: noted)
    assert_equal touch, noted.reload.last_touch_at
  end

  test "backfill selects the latest message or note and leaves recorded touches intact" do
    lead = Lead.create!(name: "Historical mail")
    lead.notes.create!(body: "Older note", created_at: 10.days.ago)
    conversation = Conversation.create!(linkable: lead)
    latest_mail = 2.days.ago.change(usec: 0)
    conversation.messages.create!(direction: "in", sent_at: latest_mail)
    conversation.messages.create!(direction: "out", sent_at: 6.days.ago)
    lead.update_columns(last_touch_at: nil, created_at: 30.days.ago)

    noted = Lead.create!(name: "Historical note")
    Conversation.create!(linkable: noted).messages.create!(direction: "in", sent_at: 12.days.ago)
    latest_note = noted.notes.create!(body: "Newer note", created_at: 3.days.ago.change(usec: 0))
    noted.update_columns(last_touch_at: nil, created_at: 30.days.ago)
    tracked = Lead.create!(name: "Tracked contact")
    touch = tracked.last_touch_at

    BackfillLeadLastTouch.new.migrate(:up)

    assert_equal latest_mail, lead.reload.last_touch_at
    assert_equal latest_note.created_at, noted.reload.last_touch_at
    assert_equal touch, tracked.reload.last_touch_at
  end

  private

  def ingest(lead, at:, id:, outbound: false)
    sender, recipient = outbound ? [ "info@sherpaholidays.com", lead.email ] : [ lead.email, "info@sherpaholidays.com" ]
    raw = "From: #{sender}\r\nTo: #{recipient}\r\nDate: #{at.rfc2822}\r\nSubject: Trip\r\n\r\nTravel plans"
    Mail::Ingester.ingest(parsed: Mail::Ingester.parse_raw(raw),
      gmail: { gm_thrid: "touch-thread", gm_msgid: id })
  end
end
