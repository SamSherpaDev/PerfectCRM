require "test_helper"

class ScheduledCallTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @lead = Lead.create!(name: "Tenzing Sherpa", email: "tenzing@example.com")
    @lead.mark_potential!
  end

  test "parses Pacific scheduled_on and scheduled_time with default 30 minute duration" do
    call = @lead.scheduled_calls.create!(
      scheduled_on: "2026-10-21",
      scheduled_time: "14:30",
      notes: "Everest Base Camp dates"
    )

    assert_equal 30, call.duration_minutes
    assert_equal "scheduled", call.status
    assert_equal Time.zone.local(2026, 10, 21, 14, 30), call.scheduled_at
    assert_equal "2026-10-21", call.scheduled_on
    assert_equal "14:30", call.scheduled_time
  end

  test "rejects blank or malformed date and time strings" do
    blank_call = @lead.scheduled_calls.build(scheduled_on: "", scheduled_time: "")
    assert_not blank_call.valid?
    assert_includes blank_call.errors[:scheduled_at].join(" "), "date and time"

    bad_time = @lead.scheduled_calls.build(scheduled_on: "2026-10-21", scheduled_time: "not-a-time")
    assert_not bad_time.valid?
    assert_includes bad_time.errors[:scheduled_at].join(" "), "valid Pacific date and time"
  end

  test "refuses scheduling on archived or converted leads" do
    archived = Lead.create!(name: "Archived lead")
    archived.archive!
    call = archived.scheduled_calls.build(scheduled_on: "2026-10-21", scheduled_time: "10:00")
    assert_not call.valid?

    converted = Lead.create!(name: "Converted lead", email: "conv@example.com")
    converted.convert_to_client!
    call_on_converted = converted.scheduled_calls.build(scheduled_on: "2026-10-21", scheduled_time: "10:00")
    assert_not call_on_converted.valid?
  end

  test "missed, upcoming, and visible scopes filter accurately" do
    travel_to Time.zone.local(2026, 10, 20, 12, 0) do
      past_call = @lead.scheduled_calls.create!(scheduled_at: 2.hours.ago, notes: "Morning check-in")
      future_call = @lead.scheduled_calls.create!(scheduled_at: 3.hours.from_now, notes: "Afternoon call")

      spam_lead = Lead.create!(name: "Spammer")
      spam_call = spam_lead.scheduled_calls.create!(scheduled_at: 1.hour.from_now)
      spam_lead.mark_as_spam!
      suspected = Lead.create!(name: "Maybe real", tag_list: Lead::SUSPECTED_SPAM_TAG)
      suspected_call = suspected.scheduled_calls.create!(scheduled_at: 4.hours.from_now)

      assert_equal [ past_call ], ScheduledCall.visible.missed.to_a
      assert_equal [ future_call, suspected_call ], ScheduledCall.visible.upcoming.to_a
      assert_not_includes ScheduledCall.visible.to_a, spam_call
      assert past_call.missed?
      assert_not future_call.missed?
    end
  end

  test "complete! logs an ActivityEvent via CallLog and marks the scheduled call completed" do
    call = @lead.scheduled_calls.create!(
      scheduled_on: "2026-10-20",
      scheduled_time: "09:00",
      notes: "Discuss acclimatization days"
    )

    freeze_time do
      event = call.complete!(outcome: "connected", save_key: "complete-call-key-1")
      assert_equal "completed", call.reload.status
      assert_equal "connected", call.outcome
      assert_equal Time.current, call.completed_at
      assert_equal event, call.activity_event
      assert_equal "call", event.kind
      assert_equal "Call: Talked", event.summary
      assert_equal "connected", event.metadata["outcome"]
      assert_nil @lead.reload.next_scheduled_call
    end
  end

  test "reschedule! and cancel! transition status and update Lead#next_scheduled_call" do
    call = @lead.scheduled_calls.create!(scheduled_on: "2026-10-20", scheduled_time: "09:00")
    assert_equal call, @lead.next_scheduled_call

    call.reschedule!(scheduled_on: "2026-10-22", scheduled_time: "16:00", duration_minutes: 45, notes: "Moved to Thursday")
    assert_equal Time.zone.local(2026, 10, 22, 16, 0), call.reload.scheduled_at
    assert_equal 45, call.duration_minutes
    assert_equal "Moved to Thursday", call.notes
    assert_equal "scheduled", call.status

    call.cancel!
    assert_equal "cancelled", call.reload.status
    assert_not_nil call.cancelled_at
    assert_nil @lead.reload.next_scheduled_call
  end

  test "closed calls cannot be completed, cancelled, or rescheduled" do
    call = @lead.scheduled_calls.create!(scheduled_on: "2026-10-20", scheduled_time: "09:00")
    call.cancel!

    assert_raises(ActiveRecord::RecordInvalid) { call.complete!(outcome: "connected", save_key: "closed-call-key-1") }
    assert_raises(ActiveRecord::RecordInvalid) { call.reschedule!(scheduled_on: "2026-10-22", scheduled_time: "16:00") }
    assert_equal 0, @lead.activity_events.where(kind: "call").count

    completed = @lead.scheduled_calls.create!(scheduled_on: "2026-10-21", scheduled_time: "09:00")
    completed.complete!(outcome: "connected", save_key: "closed-call-key-2")
    assert_raises(ActiveRecord::RecordInvalid) { completed.cancel! }
    assert_equal "completed", completed.reload.status
  end

  test "schedules, reschedules, completes, and cancels calls on active clients and hides archived client calls" do
    client = Client.create!(name: "Amara Okafor", email: "amara@example.com", phone: "+14155550177")
    Lead.create!(name: "Amara Okafor", reference: "SH-OLD", existing_client: client, created_at: 2.days.ago)
    chosen = Lead.create!(name: "Amara Okafor", reference: "SH-NEW", existing_client: client)
    call = client.scheduled_calls.create!(
      scheduled_on: "2026-10-21",
      scheduled_time: "11:00",
      notes: "Review packing list"
    )

    assert_equal client, call.owner
    assert_equal call, client.next_scheduled_call
    assert_includes ScheduledCall.visible.to_a, call

    call.reschedule!(scheduled_on: "2026-10-22", scheduled_time: "14:00", notes: "Moved to Thursday")
    assert_equal Time.zone.local(2026, 10, 22, 14, 0), call.reload.scheduled_at

    freeze_time do
      event = call.complete!(outcome: "connected", save_key: "client-call-complete-1", inquiry_id: chosen.id)
      assert_equal "completed", call.reload.status
      assert_equal event, call.activity_event
      assert_equal "Call: Talked", event.summary
      assert_equal chosen, event.subject
      assert_equal 1, chosen.activity_events.where(kind: "call").count
      assert_equal 0, Lead.find_by!(reference: "SH-OLD").activity_events.where(kind: "call").count
      assert_equal [ event.id ], client.activity_events.where(kind: "call").map { |mirror| mirror.metadata["from_lead_event_id"] }
      assert_nil client.reload.next_scheduled_call
    end

    second_call = client.scheduled_calls.create!(scheduled_on: "2026-10-25", scheduled_time: "09:30")
    client.archive!
    assert_not_includes ScheduledCall.visible.to_a, second_call

    archived_attempt = client.scheduled_calls.build(scheduled_on: "2026-10-26", scheduled_time: "10:00")
    assert_not archived_attempt.valid?
    assert_includes archived_attempt.errors.full_messages.join(" "), "active clients"
  end

  test "converting a lead to a client keeps its scheduled calls visible and actionable on the client" do
    call = @lead.scheduled_calls.create!(
      scheduled_on: "2026-10-23",
      scheduled_time: "10:30",
      notes: "Pre-conversion call"
    )

    client = @lead.convert_to_client!
    assert_equal client, call.reload.owner
    assert_equal client, call.client
    assert_equal @lead, call.lead
    assert_equal call, client.next_scheduled_call
    assert_includes ScheduledCall.visible.to_a, call

    call.reschedule!(scheduled_on: "2026-10-24", scheduled_time: "15:00")
    assert_equal Time.zone.local(2026, 10, 24, 15, 0), call.reload.scheduled_at

    call.complete!(outcome: "voicemail", save_key: "converted-client-call-1", inquiry_id: @lead.id)
    assert_equal "completed", call.reload.status
    assert_equal @lead, call.activity_event.subject
    assert_equal 1, client.activity_events.where(kind: "call").count
  end

  test "completing a client call refuses a missing or another client's inquiry and never writes an unbound call" do
    client = Client.create!(name: "Amara Okafor", email: "amara@example.com")
    other_inquiry = Lead.create!(name: "Someone Else", existing_client: Client.create!(name: "Someone Else"))
    call = client.scheduled_calls.create!(scheduled_on: "2026-10-21", scheduled_time: "11:00")

    assert_no_difference -> { ActivityEvent.where(kind: "call").count } do
      [ nil, other_inquiry.id ].each_with_index do |inquiry_id, i|
        error = assert_raises(ActiveRecord::RecordInvalid) do
          call.complete!(outcome: "connected", save_key: "client-no-inquiry-#{i}0", inquiry_id: inquiry_id)
        end
        assert_includes error.record.errors.full_messages.join(" "), "inquiries"
      end
      assert_raises(ArgumentError) do
        CallLog.record!(client, key: "client-unbound-call", occurred_at: Time.current, outcome: "connected", direction: "outbound")
      end
    end
    assert_equal "scheduled", call.reload.status

    call.reschedule!(scheduled_on: "2026-10-22", scheduled_time: "09:00")
    assert_equal Time.zone.local(2026, 10, 22, 9, 0), call.reload.scheduled_at
    call.cancel!
    assert_equal "cancelled", call.reload.status
  end

  test "scheduling a call with a client never enqueues AdConversions::LeadJob or records a call_scheduled conversion" do
    Setting.current.update!(
      meta_dataset_id: "123456789012345",
      meta_access_token: "EAAB-secret-token",
      meta_terms_accepted: true,
      google_terms_accepted: true
    )

    lead = Lead.create!(
      name: "Paid Lead Turned Client",
      email: "paid-client@example.com",
      phone: "+14155550134",
      source: "meta_ads",
      external_ref: "website_form:sub-client-test",
      metadata: {
        "attribution" => {
          "first_seen_at" => 1.day.ago.iso8601,
          "fbclid" => "fb.1.1700000000.abcdef",
          "gclid" => "Cj0K-client-click"
        },
        "acquisition" => {
          "permission" => { "state" => "allowed", "measurement" => true, "sharing" => true }
        }
      }
    )
    client = lead.convert_to_client!
    clear_enqueued_jobs

    assert_no_enqueued_jobs only: AdConversions::LeadJob do
      call = client.scheduled_calls.create!(
        scheduled_on: "2026-10-25",
        scheduled_time: "11:00",
        notes: "Post-conversion check-in"
      )
      call.complete!(outcome: "connected", save_key: "client-call-no-conversion", inquiry_id: lead.id)
    end

    AdConversions.record!(lead.reload, now: Time.current)
    assert_nil AdConversion.find_by(lead: lead, event: "call_scheduled")
  end
end
