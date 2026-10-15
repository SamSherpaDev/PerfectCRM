require "test_helper"

class TodaySummaryTest < ActiveSupport::TestCase
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

  test "not yet called lists new inquiries oldest first and ignores automatic and failed replies" do
    travel_to Time.zone.local(2026, 10, 14, 12) do
      oldest = inquiry("Oldest", 6.days.ago)
      automatic_only = inquiry("Automatic only", 5.days.ago)
      failed_only = inquiry("Failed only", 4.days.ago)
      no_mail = inquiry("No mail", 3.days.ago)
      automatic = reply(automatic_only, status: "sent")
      AutomaticFirstReply.create!(lead: automatic_only, message: automatic, email: automatic_only.email)
      reply(failed_only, status: "failed")
      reply(failed_only, status: "queued")
      reply(failed_only, status: "sending")
      reply(inquiry("Personally replied", 3.days.ago), status: "sent")
      reply(inquiry("Imported personal reply", 3.days.ago), status: "received")
      CallLog::OUTCOMES.each do |outcome|
        called = inquiry("Called #{outcome}", 3.days.ago)
        CallLog.record!(called, key: "call-#{outcome}", occurred_at: 2.days.ago,
          outcome: outcome, direction: "outbound")
      end
      inquiry("Chatting", 3.days.ago).update!(status: "chatting")
      inquiry("Archived", 3.days.ago).archive!
      inquiry("Converted", 3.days.ago).convert_to_client!
      inquiry("Too recent", 1.hour.ago)

      assert_equal [ oldest, automatic_only, failed_only, no_mail ], Today::Summary.new.not_yet_called.to_a
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
      assert_equal [ fallback, earlier_contact ], Today::Summary.new.not_yet_called.to_a
    end
  end

  test "one business day uses Pacific weekdays and strict time boundaries" do
    # Friday noon is exactly one business day before Monday noon.
    travel_to Time.zone.local(2026, 10, 12, 12) do
      older = inquiry("Over a business day", Time.zone.local(2026, 10, 9, 11, 59, 59))
      boundary = inquiry("Exactly a business day", Time.zone.local(2026, 10, 9, 12))
      inquiry("Friday afternoon", Time.zone.local(2026, 10, 9, 15))
      inquiry("Weekend", Time.zone.local(2026, 10, 10, 8))
      assert_equal [ older ], Today::Summary.new.not_yet_called.to_a
      travel 1.second
      assert_equal [ older, boundary ], Today::Summary.new.not_yet_called.to_a
    end
  end

  test "weekend hours do not age an inquiry" do
    travel_to Time.zone.local(2026, 10, 10, 12) do
      older = inquiry("Thursday", Time.zone.local(2026, 10, 8, 23, 59, 59))
      inquiry("Friday morning", Time.zone.local(2026, 10, 9, 8))
      assert_equal [ older ], Today::Summary.new.not_yet_called.to_a
      travel 1.day
      assert_equal [ older ], Today::Summary.new.not_yet_called.to_a
    end
  end

  private

  def inquiry(name, received_at)
    Lead.create!(name: name, email: "demo@example.test", received_at: received_at)
  end

  def reply(lead, status:, sent_at: 1.hour.ago)
    lead.conversations.create!(subject: "Trip").messages.create!(direction: "out", status: status,
      subject: "Trip", to_addrs: lead.email, text_body: "Hello", sent_at: sent_at)
  end
end
