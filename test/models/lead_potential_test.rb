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

  test "an inbound call of any outcome is a response and inbound voicemails never count toward the three" do
    lead = Lead.create!(name: "Called Back", email: "called-back@example.com")
    lead.mark_unsure!
    CallLog.record!(lead, key: "back-vm-1", occurred_at: 6.days.ago, outcome: "voicemail", direction: "outbound")
    CallLog.record!(lead, key: "back-vm-2", occurred_at: 5.days.ago, outcome: "voicemail", direction: "outbound")
    CallLog.record!(lead, key: "back-in-vm", occurred_at: 4.days.ago, outcome: "voicemail", direction: "inbound")
    assert lead.reload.unsure?

    CallLog.record!(lead, key: "back-vm-3", occurred_at: 3.days.ago, outcome: "voicemail", direction: "outbound")
    CallLog.record!(lead, key: "back-in-na", occurred_at: 2.days.ago - 1.hour, outcome: "no_answer", direction: "inbound")
    CallLog.record!(lead, key: "back-vm-4", occurred_at: 2.days.ago, outcome: "voicemail", direction: "outbound")
    CallLog.record!(lead, key: "back-vm-5", occurred_at: 1.day.ago, outcome: "voicemail", direction: "outbound")
    assert lead.reload.unsure?
    assert_equal 0, lead.activity_events.where(kind: "not_interested").count

    CallLog.record!(lead, key: "back-vm-6", occurred_at: 1.hour.ago, outcome: "voicemail", direction: "outbound")
    assert lead.reload.not_interested?
  end

  test "an existing client's inbound email resets the voicemail count for their Unsure inquiry" do
    client = Client.create!(name: "Returning Traveler", email: "returning-traveler@example.com")
    lead = Lead.create!(name: "Returning Traveler", email: "returning-traveler@example.com", existing_client: client)
    lead.mark_unsure!
    CallLog.record!(lead, key: "client-vm-1", occurred_at: 4.days.ago, outcome: "voicemail", direction: "outbound")
    client.conversations.create!(subject: "Next trip").messages.create!(
      direction: "in", from_address: client.email, to_addresses: [ "info@sherpaholidays.com" ],
      subject: "Re: Next trip", text_body: "Sorry I missed your call!", sent_at: 3.days.ago, status: "received"
    )
    CallLog.record!(lead, key: "client-vm-2", occurred_at: 2.days.ago, outcome: "voicemail", direction: "outbound")
    CallLog.record!(lead, key: "client-vm-3", occurred_at: 1.day.ago, outcome: "voicemail", direction: "outbound")
    assert lead.reload.unsure?

    CallLog.record!(lead, key: "client-vm-4", occurred_at: 1.hour.ago, outcome: "voicemail", direction: "outbound")
    assert lead.reload.not_interested?
    assert_equal 0, client.activity_events.where(kind: "not_interested").count
  end

  test "Interested again restarts the voicemail count so only voicemails after it can move the lead back" do
    lead = Lead.create!(name: "Second Chance", email: "second-chance@example.com")
    lead.mark_unsure!
    3.times do |i|
      CallLog.record!(lead, key: "again-vm-#{i + 1}", occurred_at: (3 - i).days.ago, outcome: "voicemail", direction: "outbound")
    end
    assert lead.reload.not_interested?

    lead.unmark_not_interested!
    restore = lead.activity_events.where(kind: "interested_again").sole
    assert_equal "Restored from Not interested", restore.summary
    assert lead.reload.unsure?

    CallLog.record!(lead, key: "again-vm-4", occurred_at: Time.current, outcome: "voicemail", direction: "outbound")
    assert lead.reload.unsure?
    CallLog.record!(lead, key: "again-vm-5", occurred_at: Time.current, outcome: "voicemail", direction: "outbound")
    assert lead.reload.unsure?
    CallLog.record!(lead, key: "again-vm-6", occurred_at: Time.current, outcome: "voicemail", direction: "outbound")
    assert lead.reload.not_interested?
    assert_equal 2, lead.activity_events.where(kind: "not_interested").count
  end

  test "marking Unsure on an auto-moved lead also restarts the voicemail count" do
    lead = Lead.create!(name: "Remarked Unsure", email: "remarked-unsure@example.com")
    lead.mark_unsure!
    3.times do |i|
      CallLog.record!(lead, key: "remark-vm-#{i + 1}", occurred_at: (3 - i).days.ago, outcome: "voicemail", direction: "outbound")
    end
    assert lead.reload.not_interested?

    lead.mark_unsure!
    assert_equal 1, lead.activity_events.where(kind: "interested_again").count
    CallLog.record!(lead, key: "remark-vm-4", occurred_at: Time.current, outcome: "voicemail", direction: "outbound")
    assert lead.reload.unsure?

    lead.mark_unsure!
    assert_equal 1, lead.activity_events.where(kind: "interested_again").count
  end

  test "Mark Unsure runs the three-voicemail check and leaves leads that answered in Unsure" do
    silent = Lead.create!(name: "Silent Traveler", email: "silent-traveler@example.com")
    open_call = silent.scheduled_calls.create!(scheduled_at: 2.days.from_now.change(hour: 11, min: 0))
    3.times do |i|
      CallLog.record!(silent, key: "silent-vm-#{i + 1}", occurred_at: (3 - i).days.ago, outcome: "voicemail", direction: "outbound")
    end
    assert_not silent.reload.not_interested?

    silent.mark_unsure!
    assert silent.not_interested?
    assert silent.reload.not_interested?
    assert_not_nil silent.unsure_marked_at
    assert_equal "cancelled", open_call.reload.status
    note = silent.activity_events.where(kind: "not_interested").sole
    assert_equal "Moved to Not interested automatically after three voicemails", note.summary
    assert_equal "three_voicemails", note.metadata["reason"]

    answered = Lead.create!(name: "Answered Traveler", email: "answered-traveler@example.com")
    CallLog.record!(answered, key: "answered-vm-1", occurred_at: 4.days.ago, outcome: "voicemail", direction: "outbound")
    CallLog.record!(answered, key: "answered-vm-2", occurred_at: 3.days.ago, outcome: "voicemail", direction: "outbound")
    CallLog.record!(answered, key: "answered-ok-1", occurred_at: 2.days.ago, outcome: "connected", direction: "outbound")
    CallLog.record!(answered, key: "answered-vm-3", occurred_at: 1.day.ago, outcome: "voicemail", direction: "outbound")

    answered.mark_unsure!
    assert answered.reload.unsure?
    assert_equal 0, answered.activity_events.where(kind: "not_interested").count
  end

  test "out-of-office replies and bounces are not a response and do not reset the voicemail count" do
    lead = Lead.create!(name: "Away Traveler", email: "away-traveler@example.com")
    lead.mark_unsure!
    convo = lead.conversations.create!(subject: "Everest base camp")
    CallLog.record!(lead, key: "away-vm-1", occurred_at: 4.days.ago, outcome: "voicemail", direction: "outbound")
    convo.messages.create!(
      direction: "in", from_address: lead.email, to_addresses: [ "info@sherpaholidays.com" ],
      subject: "Automatic reply: Everest base camp", text_body: "I am travelling until next week.", sent_at: 3.days.ago, status: "received"
    )
    convo.messages.create!(
      direction: "in", from_address: lead.email, to_addresses: [ "info@sherpaholidays.com" ],
      subject: "Re: Everest base camp", text_body: "Away from my desk.", sent_at: 3.days.ago + 1.hour, status: "received",
      inquiry_headers: { "auto-submitted" => [ "auto-replied" ] }
    )
    convo.messages.create!(
      direction: "in", from_address: "mailer-daemon@mail.example.com", to_addresses: [ "info@sherpaholidays.com" ],
      subject: "Returned mail", text_body: "Your message could not be delivered.", sent_at: 3.days.ago + 2.hours, status: "received"
    )
    CallLog.record!(lead, key: "away-vm-2", occurred_at: 2.days.ago, outcome: "voicemail", direction: "outbound")
    assert lead.reload.unsure?

    CallLog.record!(lead, key: "away-vm-3", occurred_at: 1.day.ago, outcome: "voicemail", direction: "outbound")
    assert lead.reload.not_interested?
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
