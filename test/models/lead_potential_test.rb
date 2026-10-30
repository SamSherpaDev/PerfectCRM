require "test_helper"

class LeadPotentialTest < ActiveSupport::TestCase
  test "Potential is reversible across stages and independent of fit" do
    lead = Lead.create!(name: "Follow up", status: "quoted", owner_fit_at_inquiry: "possible", fit_score: 80, fit_band: "strong")
    lead.mark_potential!
    marked_at = lead.reload.potential_marked_at
    lead.mark_potential!
    assert_equal marked_at, lead.reload.potential_marked_at
    assert lead.potential?
    assert_includes Lead.potential, lead
    assert_equal [ "quoted", "possible", 80, "strong" ], lead.attributes.values_at("status", "owner_fit_at_inquiry", "fit_score", "fit_band")
    lead.unmark_potential!
    assert_not lead.reload.potential?
    assert_not_includes Lead.potential, lead
  end

  test "spam clears Potential and restoring does not reapply it" do
    lead = Lead.create!(name: "Follow up")
    lead.mark_potential!
    lead.mark_as_spam!
    assert_nil lead.reload.potential_marked_at
    assert_not_includes Lead.potential, lead
    lead.mark_not_spam!
    assert_not lead.reload.potential?
    assert_not_includes Lead.potential, lead
  end

  test "archived converted and suspected spam leads cannot enter Potential" do
    archived = Lead.create!(name: "Archived")
    archived.mark_potential!
    archived.archive!
    converted = Lead.create!(name: "Converted")
    converted.mark_potential!
    converted.convert_to_client!
    flagged = Lead.create!(name: "Flagged", tag_list: Lead::SUSPECTED_SPAM_TAG, potential_marked_at: Time.current)
    [ archived, converted, flagged ].each do |lead|
      assert_not lead.potential?
      assert_not_includes Lead.potential, lead
      assert_raises(ActiveRecord::RecordInvalid) { lead.mark_potential! }
    end
    [ archived, converted ].each do |lead|
      assert_raises(ActiveRecord::RecordInvalid) { lead.unmark_potential! }
    end
  end

  test "three voicemails without a response move an Unsure lead to Not interested with an activity note, cancel open scheduled calls, stay idempotent, and support undo" do
    lead = Lead.create!(name: "Unreachable Unsure", email: "unreachable@example.com", source: "website_form", received_at: 5.days.ago)
    convo = lead.conversations.create!(subject: "Initial inquiry")
    convo.messages.create!(
      direction: "in", from_address: lead.email, to_addresses: [ "info@sherpaholidays.com" ],
      subject: "Initial inquiry", text_body: "Looking at Everest", sent_at: 5.days.ago, status: "received"
    )
    lead.mark_unsure!
    open_call = lead.scheduled_calls.create!(scheduled_at: 2.days.from_now.change(hour: 11, min: 0), duration_minutes: 30)

    CallLog.record!(lead, key: "unsure-vm-1", occurred_at: 3.days.ago, outcome: "voicemail", direction: "outbound")
    CallLog.record!(lead, key: "unsure-na-1", occurred_at: 2.days.ago - 2.hours, outcome: "no_answer", direction: "outbound")
    CallLog.record!(lead, key: "unsure-att-1", occurred_at: 2.days.ago - 1.hour, outcome: "attempted", direction: "outbound")
    CallLog.record!(lead, key: "unsure-vm-2", occurred_at: 2.days.ago, outcome: "voicemail", direction: "outbound")
    assert lead.reload.unsure?
    assert_not lead.not_interested?
    assert_equal "scheduled", open_call.reload.status

    third_event = CallLog.record!(lead, key: "unsure-vm-3", occurred_at: 1.day.ago, outcome: "voicemail", direction: "outbound")
    lead.reload
    assert lead.not_interested?
    assert_not lead.unsure?
    assert_not_nil lead.unsure_marked_at
    assert_includes Lead.not_interested, lead
    assert_not_includes Lead.unsure, lead
    assert_equal "cancelled", open_call.reload.status

    note_events = lead.activity_events.where(kind: "not_interested")
    assert_equal 1, note_events.count
    note_event = note_events.sole
    assert_equal "Moved to Not interested automatically after three voicemails", note_event.summary
    assert_equal "three_voicemails", note_event.metadata["reason"]
    assert_equal third_event.id, note_event.metadata["call_event_id"]

    # Double tap with the same key is idempotent
    CallLog.record!(lead, key: "unsure-vm-3", occurred_at: 1.day.ago, outcome: "voicemail", direction: "outbound")
    assert_equal 1, lead.activity_events.where(kind: "not_interested").count
    assert_equal 5, lead.activity_events.where(kind: "call").count

    # Manual undo restores the lead to Unsure, and re-logging the old key does not re-trigger Not interested
    lead.unmark_not_interested!
    lead.reload
    assert lead.unsure?
    assert_not lead.not_interested?
    assert_includes Lead.unsure, lead
    assert_not_includes Lead.not_interested, lead

    CallLog.record!(lead, key: "unsure-vm-3", occurred_at: 1.day.ago, outcome: "voicemail", direction: "outbound")
    assert lead.reload.unsure?
    assert_not lead.not_interested?
    assert_equal 1, lead.activity_events.where(kind: "not_interested").count
  end

  test "a Talked call or inbound message resets the voicemail count for an Unsure lead" do
    talked_lead = Lead.create!(name: "Talked Reset", email: "talked-reset@example.com")
    talked_lead.mark_unsure!
    CallLog.record!(talked_lead, key: "talked-vm-1", occurred_at: 5.days.ago, outcome: "voicemail", direction: "outbound")
    CallLog.record!(talked_lead, key: "talked-vm-2", occurred_at: 4.days.ago, outcome: "voicemail", direction: "outbound")
    CallLog.record!(talked_lead, key: "talked-ok-1", occurred_at: 3.days.ago, outcome: "connected", direction: "outbound")
    CallLog.record!(talked_lead, key: "talked-vm-3", occurred_at: 2.days.ago, outcome: "voicemail", direction: "outbound")
    assert talked_lead.reload.unsure?
    assert_not talked_lead.not_interested?

    CallLog.record!(talked_lead, key: "talked-vm-4", occurred_at: 1.day.ago, outcome: "voicemail", direction: "outbound")
    assert talked_lead.reload.unsure?
    assert_not talked_lead.not_interested?

    CallLog.record!(talked_lead, key: "talked-vm-5", occurred_at: 1.hour.ago, outcome: "voicemail", direction: "outbound")
    assert talked_lead.reload.not_interested?
    assert_not talked_lead.unsure?

    emailed_lead = Lead.create!(name: "Emailed Reset", email: "emailed-reset@example.com")
    emailed_lead.mark_unsure!
    convo = emailed_lead.conversations.create!(subject: "Annapurna trek")
    CallLog.record!(emailed_lead, key: "emailed-vm-1", occurred_at: 4.days.ago, outcome: "voicemail", direction: "outbound")
    convo.messages.create!(
      direction: "in", from_address: emailed_lead.email, to_addresses: [ "info@sherpaholidays.com" ],
      subject: "Re: Annapurna trek", text_body: "Sorry I missed your call!", sent_at: 3.days.ago, status: "received"
    )
    CallLog.record!(emailed_lead, key: "emailed-vm-2", occurred_at: 2.days.ago, outcome: "voicemail", direction: "outbound")
    CallLog.record!(emailed_lead, key: "emailed-vm-3", occurred_at: 1.day.ago, outcome: "voicemail", direction: "outbound")
    assert emailed_lead.reload.unsure?
    assert_not emailed_lead.not_interested?
    assert_equal 0, emailed_lead.activity_events.where(kind: "not_interested").count

    CallLog.record!(emailed_lead, key: "emailed-vm-4", occurred_at: 1.hour.ago, outcome: "voicemail", direction: "outbound")
    assert emailed_lead.reload.not_interested?
    assert_equal 1, emailed_lead.activity_events.where(kind: "not_interested").count
  end

  test "three voicemails do not move leads in New, Potential, Quoted, or client inquiries outside Unsure" do
    new_lead = Lead.create!(name: "New Tab Lead")
    potential_lead = Lead.create!(name: "Potential Tab Lead").tap(&:mark_potential!)
    quoted_lead = Lead.create!(name: "Quoted Tab Lead", status: "quoted")
    client = Client.create!(name: "Existing Client", email: "existing-client@example.com")
    client_inquiry = Lead.create!(name: "Client Inquiry", existing_client: client)

    [ new_lead, potential_lead, quoted_lead, client_inquiry ].each_with_index do |lead, idx|
      3.times do |i|
        CallLog.record!(lead, key: "other-#{idx}-vm-#{i}", occurred_at: (3 - i).days.ago, outcome: "voicemail", direction: "outbound")
      end
      assert_not lead.reload.not_interested?, "Expected #{lead.name} to stay out of Not interested"
      assert_equal 0, lead.activity_events.where(kind: "not_interested").count
    end
  end
end
