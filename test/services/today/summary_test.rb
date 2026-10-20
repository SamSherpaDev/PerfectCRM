require "test_helper"

class TodaySummaryTest < ActiveSupport::TestCase
  test "new_leads matches Lead.in_new_tab and excludes triaged leads" do
    untriaged_new = inquiry("Untriaged new", 2.days.ago)
    untriaged_chatting = Lead.create!(name: "Untriaged chatting", status: "chatting")
    untriaged_nudged = Lead.create!(name: "Untriaged nudged", status: "nudged")
    potential = inquiry("Marked potential", 2.days.ago)
    potential.mark_potential!
    unsure = inquiry("Marked unsure", 2.days.ago)
    unsure.mark_unsure!
    spam = inquiry("Marked spam", 2.days.ago)
    spam.mark_as_spam!
    archived = inquiry("Archived", 2.days.ago)
    archived.archive!
    Lead.create!(name: "Not interested", status: "lost", lost_reason: "not_a_fit")
    Lead.create!(name: "Quoted", status: "quoted")
    inquiry("Converted", 2.days.ago).convert_to_client!

    assert_equal 3, Lead.in_new_tab.count
    assert_equal 3, Today::Summary.new.new_leads

    untriaged_new.mark_potential!
    assert_equal 2, Today::Summary.new.new_leads

    untriaged_chatting.mark_unsure!
    assert_equal 1, Today::Summary.new.new_leads

    untriaged_nudged.update!(status: "lost", lost_reason: "no_reply")
    assert_equal 0, Today::Summary.new.new_leads

    potential.unmark_potential!
    assert_equal 1, Today::Summary.new.new_leads

    unsure.unmark_unsure!
    assert_equal 2, Today::Summary.new.new_leads
  end

  test "quotes for archived spam stop counting while client quotes stay visible" do
    lead = inquiry("Quoted spam", 5.days.ago)
    quote = Quote.create!(lead: lead, status: "sent", sent_at: 1.day.ago, valid_until: Date.tomorrow)
    client = Client.create!(name: "Real traveler")
    Quote.create!(client: client, status: "viewed", sent_at: 1.day.ago, valid_until: Date.tomorrow)
    assert_equal 2, Today::Summary.new.quotes_out
    lead.mark_as_spam!
    assert_equal 1, Today::Summary.new.quotes_out
    assert_equal "sent", quote.reload.status
    lead.mark_not_spam!
    assert_equal 2, Today::Summary.new.quotes_out
  end

  test "spam archive removes inquiry replies and tasks from Today and restoration brings them back" do
    lead = inquiry("Spam demo", 5.days.ago)
    thread = lead.conversations.create!(subject: "Spam inquiry")
    thread.messages.create!(direction: "in", status: "received", sent_at: 2.days.ago,
      from_address: lead.email, text_body: "Demo spam")
    task = lead.tasks.create!(title: "Review inquiry", due_on: Date.current)
    overdue = lead.tasks.create!(title: "Old inquiry task", due_on: Date.yesterday)
    summary = Today::Summary.new
    assert_includes summary.not_yet_called, lead
    assert_includes summary.replies_waiting, thread
    assert_includes summary.followups_due, task
    waiting_count = summary.waiting_on_you

    lead.mark_as_spam!
    summary = Today::Summary.new
    assert_not_includes summary.not_yet_called, lead
    assert_not_includes summary.replies_waiting, thread
    assert_equal waiting_count - 1, summary.waiting_on_you
    assert_not_includes summary.followups_due, task
    assert_not_includes summary.overdue, overdue
    assert_not_includes summary.followups, task
    assert_nil task.reload.done_at

    lead.mark_not_spam!
    summary = Today::Summary.new
    assert_includes summary.not_yet_called, lead
    assert_includes summary.replies_waiting, thread
    assert_includes summary.followups_due, task
    assert_includes summary.overdue, overdue
  end

  test "not yet called prioritizes uncalled phone inquiries oldest first, then Day 1 (2nd try) and Day 3 (3rd try) retries, and drops connected, scheduled, not-interested, spam, archived, and 3-attempt leads" do
    travel_to Time.zone.local(2026, 11, 3, 12) do
      oldest_uncalled = inquiry("Oldest uncalled", 2.days.ago)
      newest_uncalled = inquiry("Newest uncalled", 30.minutes.ago)
      Lead.create!(name: "No phone inquiry", email: "nophone@example.test", received_at: 3.days.ago)

      retry_second_older = inquiry("Due 2nd try (voicemail yesterday)", 3.days.ago)
      CallLog.record!(retry_second_older, key: "call-vm-01", occurred_at: 1.day.ago, outcome: "voicemail", direction: "outbound")

      retry_second_newer = inquiry("Due 2nd try (no answer yesterday evening)", 2.days.ago)
      CallLog.record!(retry_second_newer, key: "call-na-01", occurred_at: Time.zone.local(2026, 11, 2, 18), outcome: "no_answer", direction: "outbound")

      retry_third_due = inquiry("Due 3rd try (2 days after 2nd try)", 5.days.ago)
      CallLog.record!(retry_third_due, key: "call-try3-1", occurred_at: 4.days.ago, outcome: "voicemail", direction: "outbound")
      CallLog.record!(retry_third_due, key: "call-try3-2", occurred_at: 2.days.ago, outcome: "no_answer", direction: "outbound")

      # Not yet due for 2nd try (called earlier today)
      called_today = inquiry("Called today (wait until Day 1)", 1.day.ago)
      CallLog.record!(called_today, key: "call-today-1", occurred_at: 2.hours.ago, outcome: "voicemail", direction: "outbound")

      # Not yet due for 3rd try (attempt 2 was only 1 day ago)
      third_not_due = inquiry("Attempt 2 yesterday (wait 2 days for 3rd try)", 4.days.ago)
      CallLog.record!(third_not_due, key: "call-nd3-1", occurred_at: 3.days.ago, outcome: "voicemail", direction: "outbound")
      CallLog.record!(third_not_due, key: "call-nd3-2", occurred_at: 1.day.ago, outcome: "voicemail", direction: "outbound")

      # Drops off after 3 attempts
      three_tries = inquiry("Used 3 attempts", 6.days.ago)
      CallLog.record!(three_tries, key: "call-max-1", occurred_at: 5.days.ago, outcome: "voicemail", direction: "outbound")
      CallLog.record!(three_tries, key: "call-max-2", occurred_at: 4.days.ago, outcome: "no_answer", direction: "outbound")
      CallLog.record!(three_tries, key: "call-max-3", occurred_at: 2.days.ago, outcome: "voicemail", direction: "outbound")

      # Drops off once connected (Talked)
      connected = inquiry("Talked", 4.days.ago)
      CallLog.record!(connected, key: "call-conn-1", occurred_at: 3.days.ago, outcome: "voicemail", direction: "outbound")
      CallLog.record!(connected, key: "call-conn-2", occurred_at: 2.days.ago, outcome: "connected", direction: "outbound")

      # Drops off when a call is scheduled
      scheduled = inquiry("Has scheduled call", 2.days.ago)
      scheduled.scheduled_calls.create!(scheduled_at: 1.day.from_now)

      # Drops off when Not interested, spam, archived, converted, or lost
      inquiry("Not interested", 3.days.ago).mark_not_interested!
      inquiry("Spam", 3.days.ago).mark_as_spam!
      inquiry("Archived", 3.days.ago).archive!
      inquiry("Converted", 3.days.ago).convert_to_client!
      inquiry("Lost", 3.days.ago).update!(status: "lost", lost_reason: "no_reply")

      summary = Today::Summary.new
      assert_equal [
        newest_uncalled,
        retry_second_older,
        retry_second_newer,
        retry_third_due,
        oldest_uncalled
      ], summary.not_yet_called.to_a

      assert_equal [
        [ newest_uncalled, 1, "1st try" ],
        [ retry_second_older, 2, "2nd try" ],
        [ retry_second_newer, 2, "2nd try" ],
        [ retry_third_due, 3, "3rd try" ],
        [ oldest_uncalled, 1, "1st try" ]
      ], summary.call_entries.map { |e| [ e.lead, e.attempt, e.attempt_label ] }
    end
  end

  test "uses received time before creation time and does not count contact before the inquiry" do
    travel_to Time.zone.local(2026, 10, 14, 12) do
      old_created = inquiry("Recently received", 2.hours.ago)
      old_created.update_columns(created_at: 1.month.ago)
      fallback = inquiry("Creation fallback", nil)
      fallback.update_columns(created_at: 3.days.ago)
      earlier_contact = inquiry("Earlier contact", 2.days.ago)
      reply(earlier_contact, status: "sent", sent_at: 3.days.ago)
      CallLog.record!(earlier_contact, key: "earlier-call", occurred_at: 3.days.ago,
        outcome: "connected", direction: "inbound")
      assert_equal [ old_created, fallback, earlier_contact ], Today::Summary.new.not_yet_called.to_a
    end
  end

  test "Day 0 -> Day 1 -> Day 3 retry lifecycle progresses through 1st, 2nd, and 3rd try and then drops off" do
    travel_to Time.zone.local(2026, 10, 20, 10) do
      lead = inquiry("Cadence traveler", 15.minutes.ago)

      # Day 0: appears immediately as 1st try
      entry = Today::Summary.new.call_entries.sole
      assert_equal [ lead, 1, "1st try" ], [ entry.lead, entry.attempt, entry.attempt_label ]

      # Day 0 attempt 1 -> voicemail: drops off for the rest of Day 0
      CallLog.record!(lead, key: "cadence-1", occurred_at: Time.current, outcome: "voicemail", direction: "outbound")
      assert_empty Today::Summary.new.call_entries

      # Day 1: due for 2nd try
      travel 1.day
      entry = Today::Summary.new.call_entries.sole
      assert_equal [ lead, 2, "2nd try" ], [ entry.lead, entry.attempt, entry.attempt_label ]

      # Day 1 attempt 2 -> no_answer: drops off on Day 1 and stays off on Day 2
      CallLog.record!(lead, key: "cadence-2", occurred_at: Time.current, outcome: "no_answer", direction: "outbound")
      assert_empty Today::Summary.new.call_entries
      travel 1.day
      assert_empty Today::Summary.new.call_entries

      # Day 3 (2 days after attempt 2): due for 3rd try
      travel 1.day
      entry = Today::Summary.new.call_entries.sole
      assert_equal [ lead, 3, "3rd try" ], [ entry.lead, entry.attempt, entry.attempt_label ]

      # Day 3 attempt 3 -> voicemail: used 3 attempts, drops off permanently
      CallLog.record!(lead, key: "cadence-3", occurred_at: Time.current, outcome: "voicemail", direction: "outbound")
      assert_empty Today::Summary.new.call_entries
      travel 5.days
      assert_empty Today::Summary.new.call_entries
    end
  end

  test "an Attempted call is an unanswered try that continues the Day 0, Day 1, Day 3 cadence" do
    travel_to Time.zone.local(2026, 10, 20, 10) do
      lead = inquiry("Attempted traveler", 15.minutes.ago)

      CallLog.record!(lead, key: "attempted-1", occurred_at: Time.current, outcome: "attempted", direction: "outbound")
      assert_empty Today::Summary.new.call_entries

      travel 1.day
      entry = Today::Summary.new.call_entries.sole
      assert_equal [ lead, 2, "2nd try", "attempted" ],
        [ entry.lead, entry.attempt, entry.attempt_label, entry.last_call.metadata["outcome"] ]

      CallLog.record!(lead, key: "attempted-2", occurred_at: Time.current, outcome: "attempted", direction: "outbound")
      travel 2.days
      entry = Today::Summary.new.call_entries.sole
      assert_equal [ lead, 3, "3rd try" ], [ entry.lead, entry.attempt, entry.attempt_label ]

      CallLog.record!(lead, key: "attempted-3", occurred_at: Time.current, outcome: "attempted", direction: "outbound")
      travel 5.days
      assert_empty Today::Summary.new.call_entries
    end
  end

  test "fresh inquiries lead newest first, then due retries, then older first tries up to 14 days old" do
    travel_to Time.zone.local(2026, 11, 3, 12) do
      fresh_older = inquiry("Fresh 20 hours", 20.hours.ago)
      fresh_newest = inquiry("Fresh 10 minutes", 10.minutes.ago)
      older_newer = inquiry("Older 3 days", 3.days.ago)
      older_oldest = inquiry("Older 13 days", 13.days.ago)
      inquiry("Too old 15 days", 15.days.ago)
      retry_due = inquiry("Retry due", 2.days.ago)
      CallLog.record!(retry_due, key: "groups-retry-1", occurred_at: 1.day.ago, outcome: "no_answer", direction: "outbound")

      assert_equal [ fresh_newest, fresh_older, retry_due, older_oldest, older_newer ], Today::Summary.new.not_yet_called
    end
  end

  test "calls logged before the cadence start keep a lead off the list until a new call starts its cadence" do
    travel_to Time.zone.local(2026, 10, 20, 12) do
      backlog = inquiry("Called Oct 15", Time.zone.local(2026, 10, 8, 9))
      CallLog.record!(backlog, key: "backlog-call-1", occurred_at: Time.zone.local(2026, 10, 15, 11), outcome: "no_answer", direction: "outbound")
      old_backlog = inquiry("Old single call", 60.days.ago)
      CallLog.record!(old_backlog, key: "stale-call-1", occurred_at: 30.days.ago, outcome: "no_answer", direction: "outbound")
      assert_empty Today::Summary.new.call_entries

      CallLog.record!(backlog, key: "backlog-call-2", occurred_at: Time.current, outcome: "voicemail", direction: "outbound")
      assert_empty Today::Summary.new.call_entries

      travel 1.day
      entry = Today::Summary.new.call_entries.sole
      assert_equal [ backlog, 2, "2nd try" ], [ entry.lead, entry.attempt, entry.attempt_label ]

      CallLog.record!(backlog, key: "backlog-call-3", occurred_at: Time.current, outcome: "no_answer", direction: "outbound")
      travel 2.days
      entry = Today::Summary.new.call_entries.sole
      assert_equal [ backlog, 3, "3rd try" ], [ entry.lead, entry.attempt, entry.attempt_label ]
    end
  end

  test "uncalled inquiries appear as first tries only up to 14 days old" do
    travel_to Time.zone.local(2026, 11, 3, 12) do
      edge = inquiry("Exactly 14 days", 14.days.ago)
      inquiry("Just over 14 days", 14.days.ago - 1.minute)
      assert_equal [ edge ], Today::Summary.new.not_yet_called
    end
  end

  test "a flagged but unreviewed inquiry stays on the call list until confirmed as spam" do
    travel_to Time.zone.local(2026, 10, 20, 10) do
      flagged = Lead.create!(name: "Anna Lindqvist", email: "annalindqvist@gmail.com", phone_raw: "+1 415 555 0199",
        received_at: 1.hour.ago, spam_score: 25, tag_list: Lead::SUSPECTED_SPAM_TAG)
      assert flagged.suspected_spam?

      assert_equal [ flagged ], Today::Summary.new.not_yet_called

      flagged.mark_as_spam!
      assert_empty Today::Summary.new.not_yet_called
    end
  end

  private

  def inquiry(name, received_at, phone: "+1 415 555 0134")
    Lead.create!(name: name, email: "demo@example.test", phone_raw: phone, received_at: received_at)
  end

  def reply(lead, status:, sent_at: 1.hour.ago)
    lead.conversations.create!(subject: "Trip").messages.create!(direction: "out", status: status,
      subject: "Trip", to_addrs: lead.email, text_body: "Hello", sent_at: sent_at)
  end
end
