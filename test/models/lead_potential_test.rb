require "test_helper"
require_relative "../../db/migrate/20261101202153_move_unanswered_unsure_leads_to_not_interested"

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

  test "three unanswered calls (Voicemail or No answer) without a response move an Unsure lead to Re-contact with an activity note, leave Attempted uncounted, cancel open scheduled calls, stay idempotent, and support undo" do
    lead = Lead.create!(name: "Don Campbell", email: "unreachable@example.com", source: "website_form", received_at: 20.days.ago)
    convo = lead.conversations.create!(subject: "Initial inquiry")
    convo.messages.create!(
      direction: "in", from_address: lead.email, to_addresses: [ "info@sherpaholidays.com" ],
      subject: "Initial inquiry", text_body: "Looking at Everest", sent_at: 20.days.ago, status: "received"
    )
    lead.mark_unsure!
    open_call = lead.scheduled_calls.create!(scheduled_at: 2.days.from_now.change(hour: 11, min: 0), duration_minutes: 30)

    CallLog.record!(lead, key: "unsure-vm-1", occurred_at: 13.days.ago, outcome: "voicemail", direction: "outbound")
    CallLog.record!(lead, key: "unsure-att-1", occurred_at: 4.days.ago, outcome: "attempted", direction: "outbound")
    CallLog.record!(lead, key: "unsure-na-1", occurred_at: 3.days.ago, outcome: "no_answer", direction: "outbound")
    assert lead.reload.unsure?
    assert_not lead.recontact?
    assert_not lead.not_interested?
    assert_equal "scheduled", open_call.reload.status

    third_event = CallLog.record!(lead, key: "unsure-vm-2", occurred_at: 1.day.ago, outcome: "voicemail", direction: "outbound")
    lead.reload
    assert lead.recontact?
    assert_not lead.not_interested?
    assert_not lead.unsure?
    assert_not_nil lead.unsure_marked_at
    assert_equal Date.current + 3.months, lead.recontact_on
    assert_includes Lead.recontact, lead
    assert_not_includes Lead.unsure, lead
    assert_not_includes Lead.not_interested, lead
    assert_equal "cancelled", open_call.reload.status

    note_events = lead.activity_events.where(kind: "recontact")
    assert_equal 1, note_events.count
    note_event = note_events.sole
    assert_equal "Moved to Re-contact automatically after three unanswered calls", note_event.summary
    assert_equal "three_unanswered_calls", note_event.metadata["reason"]
    assert_equal third_event.id, note_event.metadata["call_event_id"]

    # Double tap with the same key is idempotent
    CallLog.record!(lead, key: "unsure-vm-2", occurred_at: 1.day.ago, outcome: "voicemail", direction: "outbound")
    assert_equal 1, lead.activity_events.where(kind: "recontact").count
    assert_equal 4, lead.activity_events.where(kind: "call").count

    # Manual undo restores the lead to Unsure, and re-logging the old key does not re-trigger Re-contact
    lead.unmark_recontact!
    lead.reload
    assert lead.unsure?
    assert_not lead.recontact?
    assert_includes Lead.unsure, lead
    assert_not_includes Lead.recontact, lead

    CallLog.record!(lead, key: "unsure-vm-2", occurred_at: 1.day.ago, outcome: "voicemail", direction: "outbound")
    assert lead.reload.unsure?
    assert_not lead.recontact?
    assert_equal 1, lead.activity_events.where(kind: "recontact").count
  end

  test "logging a third unanswered call as No answer also moves an Unsure lead to Re-contact while Attempted stays uncounted" do
    lead = Lead.create!(name: "No Answer Third", email: "no-answer-third@example.com")
    lead.mark_unsure!

    CallLog.record!(lead, key: "na-third-1", occurred_at: 4.days.ago, outcome: "no_answer", direction: "outbound")
    CallLog.record!(lead, key: "na-third-att", occurred_at: 3.days.ago, outcome: "attempted", direction: "outbound")
    CallLog.record!(lead, key: "na-third-2", occurred_at: 2.days.ago, outcome: "voicemail", direction: "outbound")
    assert lead.reload.unsure?
    assert_not lead.recontact?

    third = CallLog.record!(lead, key: "na-third-3", occurred_at: 1.day.ago, outcome: "no_answer", direction: "outbound")
    assert lead.reload.recontact?
    assert_not lead.not_interested?
    note = lead.activity_events.where(kind: "recontact").sole
    assert_equal "Moved to Re-contact automatically after three unanswered calls", note.summary
    assert_equal third.id, note.metadata["call_event_id"]
  end

  test "a Talked call or inbound message resets the voicemail count for an Unsure lead" do
    talked_lead = Lead.create!(name: "Talked Reset", email: "talked-reset@example.com")
    talked_lead.mark_unsure!
    CallLog.record!(talked_lead, key: "talked-vm-1", occurred_at: 5.days.ago, outcome: "voicemail", direction: "outbound")
    CallLog.record!(talked_lead, key: "talked-vm-2", occurred_at: 4.days.ago, outcome: "voicemail", direction: "outbound")
    CallLog.record!(talked_lead, key: "talked-ok-1", occurred_at: 3.days.ago, outcome: "connected", direction: "outbound")
    CallLog.record!(talked_lead, key: "talked-vm-3", occurred_at: 2.days.ago, outcome: "voicemail", direction: "outbound")
    assert talked_lead.reload.unsure?
    assert_not talked_lead.recontact?

    CallLog.record!(talked_lead, key: "talked-vm-4", occurred_at: 1.day.ago, outcome: "voicemail", direction: "outbound")
    assert talked_lead.reload.unsure?
    assert_not talked_lead.recontact?

    CallLog.record!(talked_lead, key: "talked-vm-5", occurred_at: 1.hour.ago, outcome: "voicemail", direction: "outbound")
    assert talked_lead.reload.recontact?
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
    assert_not emailed_lead.recontact?
    assert_equal 0, emailed_lead.activity_events.where(kind: "recontact").count

    CallLog.record!(emailed_lead, key: "emailed-vm-4", occurred_at: 1.hour.ago, outcome: "voicemail", direction: "outbound")
    assert emailed_lead.reload.recontact?
    assert_equal 1, emailed_lead.activity_events.where(kind: "recontact").count
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
    assert_equal 0, lead.activity_events.where(kind: "recontact").count

    CallLog.record!(lead, key: "back-vm-6", occurred_at: 1.hour.ago, outcome: "voicemail", direction: "outbound")
    assert lead.reload.recontact?
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
    assert lead.reload.recontact?
    assert_equal 0, client.activity_events.where(kind: "recontact").count
  end

  test "a returning client's email filed on their client record resets the voicemail count for a website lead" do
    client = Client.create!(name: "Jane Traveler", email: "jane-traveler@example.com")
    lead = Lead.create!(name: "Jane Traveler", email: "jane-traveler@example.com", source: "website_form")
    assert_nil lead.existing_client
    lead.mark_unsure!
    CallLog.record!(lead, key: "jane-vm-1", occurred_at: 4.days.ago, outcome: "voicemail", direction: "outbound")
    convo = client.conversations.create!(subject: "Missed call")
    convo.messages.create!(
      direction: "in", from_address: "Jane-Traveler@example.com", to_addresses: [ "info@sherpaholidays.com" ],
      subject: "Missed call", text_body: "Sorry I missed your call, free Thursday?", sent_at: 3.days.ago, status: "received"
    )
    CallLog.record!(lead, key: "jane-vm-2", occurred_at: 2.days.ago, outcome: "voicemail", direction: "outbound")
    CallLog.record!(lead, key: "jane-vm-3", occurred_at: 1.day.ago, outcome: "voicemail", direction: "outbound")
    assert lead.reload.unsure?
    assert_equal 0, lead.activity_events.where(kind: "recontact").count

    CallLog.record!(lead, key: "jane-vm-4", occurred_at: 1.hour.ago, outcome: "voicemail", direction: "outbound")
    assert lead.reload.recontact?
  end

  test "Restore from Re-contact restarts the voicemail count so only voicemails after it can move the lead back" do
    lead = Lead.create!(name: "Second Chance", email: "second-chance@example.com")
    lead.mark_unsure!
    3.times do |i|
      CallLog.record!(lead, key: "again-vm-#{i + 1}", occurred_at: (3 - i).days.ago, outcome: "voicemail", direction: "outbound")
    end
    assert lead.reload.recontact?

    lead.unmark_recontact!
    restore = lead.activity_events.where(kind: "recontact_restored").sole
    assert_equal "Restored from Re-contact", restore.summary
    assert lead.reload.unsure?

    CallLog.record!(lead, key: "again-vm-4", occurred_at: Time.current, outcome: "voicemail", direction: "outbound")
    assert lead.reload.unsure?
    CallLog.record!(lead, key: "again-vm-5", occurred_at: Time.current, outcome: "voicemail", direction: "outbound")
    assert lead.reload.unsure?
    CallLog.record!(lead, key: "again-vm-6", occurred_at: Time.current, outcome: "voicemail", direction: "outbound")
    assert lead.reload.recontact?
    assert_equal 2, lead.activity_events.where(kind: "recontact").count
  end

  test "marking Unsure on an auto-moved lead also restarts the voicemail count" do
    lead = Lead.create!(name: "Remarked Unsure", email: "remarked-unsure@example.com")
    lead.mark_unsure!
    3.times do |i|
      CallLog.record!(lead, key: "remark-vm-#{i + 1}", occurred_at: (3 - i).days.ago, outcome: "voicemail", direction: "outbound")
    end
    assert lead.reload.recontact?

    lead.mark_unsure!
    assert_equal 1, lead.activity_events.where(kind: "recontact_restored").count
    CallLog.record!(lead, key: "remark-vm-4", occurred_at: Time.current, outcome: "voicemail", direction: "outbound")
    assert lead.reload.unsure?

    lead.mark_unsure!
    assert_equal 1, lead.activity_events.where(kind: "recontact_restored").count
  end

  test "Mark Unsure runs the three-unanswered-calls check and leaves leads that answered in Unsure" do
    silent = Lead.create!(name: "Silent Traveler", email: "silent-traveler@example.com")
    open_call = silent.scheduled_calls.create!(scheduled_at: 2.days.from_now.change(hour: 11, min: 0))
    CallLog.record!(silent, key: "silent-vm-1", occurred_at: 3.days.ago, outcome: "voicemail", direction: "outbound")
    CallLog.record!(silent, key: "silent-na-2", occurred_at: 2.days.ago, outcome: "no_answer", direction: "outbound")
    CallLog.record!(silent, key: "silent-vm-3", occurred_at: 1.day.ago, outcome: "voicemail", direction: "outbound")
    assert_not silent.reload.recontact?

    silent.mark_unsure!
    assert silent.recontact?
    assert silent.reload.recontact?
    assert_not_nil silent.unsure_marked_at
    assert_equal "cancelled", open_call.reload.status
    note = silent.activity_events.where(kind: "recontact").sole
    assert_equal "Moved to Re-contact automatically after three unanswered calls", note.summary
    assert_equal "three_unanswered_calls", note.metadata["reason"]

    answered = Lead.create!(name: "Answered Traveler", email: "answered-traveler@example.com")
    CallLog.record!(answered, key: "answered-vm-1", occurred_at: 4.days.ago, outcome: "voicemail", direction: "outbound")
    CallLog.record!(answered, key: "answered-vm-2", occurred_at: 3.days.ago, outcome: "no_answer", direction: "outbound")
    CallLog.record!(answered, key: "answered-ok-1", occurred_at: 2.days.ago, outcome: "connected", direction: "outbound")
    CallLog.record!(answered, key: "answered-vm-3", occurred_at: 1.day.ago, outcome: "voicemail", direction: "outbound")

    answered.mark_unsure!
    assert answered.reload.unsure?
    assert_equal 0, answered.activity_events.where(kind: "recontact").count
  end

  test "team mail, out-of-office replies, and bounces are not a response and do not reset the voicemail count" do
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
    convo.messages.create!(
      direction: "in", from_address: "pemba@sherpaholidays.com", to_addresses: [ lead.email ], cc_addresses: [ "info@sherpaholidays.com" ],
      subject: "Re: Everest base camp", text_body: "Following up on my voicemail.", sent_at: 3.days.ago + 3.hours, status: "received"
    )
    CallLog.record!(lead, key: "away-vm-2", occurred_at: 2.days.ago, outcome: "voicemail", direction: "outbound")
    assert lead.reload.unsure?

    CallLog.record!(lead, key: "away-vm-3", occurred_at: 1.day.ago, outcome: "voicemail", direction: "outbound")
    assert lead.reload.recontact?
  end

  test "a real reply synced after the automatic move returns the lead to Unsure with a note" do
    lead = Lead.create!(name: "Back From Trek", email: "back-from-trek@example.com")
    lead.mark_unsure!
    3.times do |index|
      CallLog.record!(lead, key: "back-vm-#{index + 1}", occurred_at: (3 - index).days.ago, outcome: "voicemail", direction: "outbound")
    end
    assert lead.reload.recontact?

    result = ingest_live_reply(from: "Back-From-Trek@example.com", subject: "Re: Your trip")
    assert_equal "pending", result[:message].reply_alert_state
    assert lead.reload.unsure?
    restore = lead.activity_events.where(kind: "recontact_restored").sole
    assert_equal "Moved back to Unsure: they replied after the automatic move.", restore.summary
    assert_equal "automatic", restore.metadata["actor"]

    ingest_live_reply(from: lead.email, subject: "Re: Your trip again")
    assert_equal 1, lead.activity_events.where(kind: "recontact_restored").count
  end

  test "out-of-office replies and bounces leave an automatically moved lead in Re-contact" do
    lead = Lead.create!(name: "Still Away", email: "still-away@example.com")
    lead.mark_unsure!
    3.times do |index|
      CallLog.record!(lead, key: "away-vm-#{index + 1}", occurred_at: (3 - index).days.ago, outcome: "voicemail", direction: "outbound")
    end
    assert lead.reload.recontact?

    ingest_live_reply(from: lead.email, subject: "Automatic reply: Your trip")
    ingest_live_reply(from: lead.email, subject: "Re: Your trip", header: "Auto-Submitted: auto-replied")
    ingest_live_reply(from: lead.email, subject: "Re: Your trip", header: "Return-Path: <>")
    assert lead.reload.recontact?
    assert_not lead.activity_events.exists?(kind: "recontact_restored")
  end

  test "a reply never restores a lead marked Not interested by hand, even after an automatic move" do
    by_hand = Lead.create!(name: "Said No", email: "said-no@example.com")
    by_hand.mark_unsure!
    by_hand.mark_not_interested!
    re_marked = Lead.create!(name: "Said No Later", email: "said-no-later@example.com")
    re_marked.mark_unsure!
    3.times do |index|
      CallLog.record!(re_marked, key: "later-vm-#{index + 1}", occurred_at: (3 - index).days.ago, outcome: "voicemail", direction: "outbound")
    end
    assert re_marked.reload.recontact?
    re_marked.unmark_recontact!
    travel 1.minute
    re_marked.mark_not_interested!

    ingest_live_reply(from: by_hand.email, subject: "Re: Your trip")
    ingest_live_reply(from: re_marked.email, subject: "Re: Your trip")
    assert by_hand.reload.not_interested?
    assert re_marked.reload.not_interested?
    assert_not by_hand.activity_events.exists?(kind: "interested_again")
    assert_not re_marked.activity_events.exists?(kind: "interested_again")
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
      assert_not lead.recontact?, "Expected #{lead.name} to stay out of Re-contact"
      assert_equal 0, lead.activity_events.where(kind: [ "not_interested", "recontact" ]).count
    end
  end

  test "a lead already moved under the legacy three-voicemails note is still restored to Unsure on a real reply" do
    lead = Lead.create!(name: "Legacy Auto Moved", email: "legacy-auto-moved@example.com")
    lead.mark_unsure!
    lead.mark_not_interested!
    lead.activity_events.create!(
      kind: "not_interested",
      summary: "Moved to Not interested automatically after three voicemails",
      occurred_at: Time.current,
      metadata: { "reason" => "three_voicemails", "actor" => "automatic" }
    )
    assert lead.reload.not_interested?

    ingest_live_reply(from: lead.email, subject: "Re: Your trip")
    assert lead.reload.unsure?
    assert_not lead.not_interested?
    restore = lead.activity_events.where(kind: "interested_again").sole
    assert_equal "Moved back to Unsure: they replied after the automatic move.", restore.summary
  end

  test "the one-time backfill migration moves existing qualifying Unsure leads like Don Campbell once and leaves non-qualifying leads untouched" do
    don = Lead.create!(name: "Don Campbell", email: "don-campbell@example.com", unsure_marked_at: 14.days.ago)
    open_call = don.scheduled_calls.create!(scheduled_at: 2.days.from_now.change(hour: 11, min: 0))
    [
      [ "don-mig-1", "voicemail", Time.zone.local(2026, 10, 19, 10, 0) ],
      [ "don-mig-2", "no_answer", Time.zone.local(2026, 10, 29, 10, 0) ],
      [ "don-mig-3", "voicemail", Time.zone.local(2026, 11, 1, 10, 0) ]
    ].each do |key, outcome, at|
      don.activity_events.create!(
        kind: "call", idempotency_key: key, summary: "Call: #{CallLog::LABELS.fetch(outcome)}",
        occurred_at: at, metadata: { "inquiry_id" => don.id, "direction" => "outbound", "outcome" => outcome }
      )
    end

    two_unanswered_plus_attempted = Lead.create!(name: "Two Plus Attempted", email: "two-att@example.com", unsure_marked_at: 10.days.ago)
    CallLog.record!(two_unanswered_plus_attempted, key: "tpa-call-1", occurred_at: 3.days.ago, outcome: "voicemail", direction: "outbound")
    CallLog.record!(two_unanswered_plus_attempted, key: "tpa-call-2", occurred_at: 2.days.ago, outcome: "no_answer", direction: "outbound")
    CallLog.record!(two_unanswered_plus_attempted, key: "tpa-call-3", occurred_at: 1.day.ago, outcome: "attempted", direction: "outbound")

    potential_three = Lead.create!(name: "Potential Three", email: "pot-three@example.com").tap(&:mark_potential!)
    3.times do |i|
      CallLog.record!(potential_three, key: "pot-call-#{i + 1}", occurred_at: (3 - i).days.ago, outcome: "no_answer", direction: "outbound")
    end

    ActiveRecord::Migration.suppress_messages { MoveUnansweredUnsureLeadsToNotInterested.new.migrate(:up) }

    assert don.reload.not_interested?
    assert_not don.unsure?
    assert_not_nil don.unsure_marked_at
    assert_equal "cancelled", open_call.reload.status
    note = don.activity_events.where(kind: "not_interested").sole
    assert_equal "Moved to Not interested automatically after three unanswered calls", note.summary
    assert_equal "three_unanswered_calls", note.metadata["reason"]

    assert two_unanswered_plus_attempted.reload.unsure?
    assert_not two_unanswered_plus_attempted.not_interested?
    assert potential_three.reload.potential?
    assert_not potential_three.not_interested?

    # Safe and idempotent on re-run, and respects manual Interested again
    ActiveRecord::Migration.suppress_messages { MoveUnansweredUnsureLeadsToNotInterested.new.migrate(:up) }
    assert_equal 1, don.activity_events.where(kind: "not_interested").count

    don.unmark_not_interested!
    assert don.reload.unsure?
    ActiveRecord::Migration.suppress_messages { MoveUnansweredUnsureLeadsToNotInterested.new.migrate(:up) }
    assert don.reload.unsure?
    assert_equal 1, don.activity_events.where(kind: "not_interested").count
  end

  private

  def ingest_live_reply(from:, subject:, header: nil)
    raw = "From: #{from}\r\nTo: info@sherpaholidays.com\r\nSubject: #{subject}\r\n#{"#{header}\r\n" if header}\r\nStill keen, I was away."
    Mail::Ingester.ingest(parsed: Mail::Ingester.parse_raw(raw), provider: { message_id: SecureRandom.uuid }, alert: true)
  end
end
