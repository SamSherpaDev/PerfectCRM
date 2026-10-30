require "test_helper"
require_relative "../support/google_sign_in_test_helper"

class CallsRequestsTest < ActionDispatch::IntegrationTest
  include GoogleSignInTestHelper
  setup { sign_in }

  test "a one-tap call without a time logs an outbound call now" do
    lead = Lead.create!(name: "Quick call")
    freeze_time do
      post lead_calls_path(lead), params: { save_key: "quick-call-1", outcome: "connected", direction: "outbound" }
      assert_redirected_to lead_path(lead, anchor: "record-details")
      assert_equal "Call logged: Talked.", flash[:notice]
      call = lead.activity_events.find_by!(kind: "call")
      assert_equal Time.current, call.occurred_at
      assert_equal "Call: Talked", call.summary
    end
  end

  test "a double tap with one save key logs one call" do
    lead = Lead.create!(name: "Double tap")
    2.times do
      post lead_calls_path(lead), params: { save_key: "double-tap-1", outcome: "voicemail", direction: "outbound" }
    end
    assert_equal 1, lead.activity_events.where(kind: "call").count
  end

  test "lead and client pages show one-tap buttons and recent calls per inquiry" do
    client = Client.create!(name: "Two trips", email: "two@example.com")
    first = Lead.create!(name: "Two trips", reference: "SH-ONE", existing_client: client, created_at: 2.days.ago)
    second = Lead.create!(name: "Two trips", reference: "SH-TWO", existing_client: client)
    CallLog.record!(first, key: "first-trip-call", occurred_at: 1.day.ago, outcome: "no_answer", direction: "outbound")

    get client_path(client)
    assert_select ".calls .calls-inquiry", count: 2
    assert_select ".calls-inquiry[aria-label='Calls for SH-TWO'] input[name=inquiry_id][value=?]", second.id.to_s
    assert_select ".calls-inquiry[aria-label='Calls for SH-ONE'] .calls-recent li", text: /No answer/
    assert_select ".calls-inquiry[aria-label='Calls for SH-TWO'] .calls-recent", count: 0

    get lead_path(first)
    assert_select ".call-choices button[name=outcome]", count: 3 do |buttons|
      assert_equal [ "Talked", "Voicemail", "No answer" ], buttons.map { |button| button.text.strip }
    end
    assert_select ".call-choices input[name=direction][value=outbound]"
  end

  test "logging a third unanswered voicemail via the one-tap endpoint moves an Unsure lead to Not interested, completes due scheduled calls, cancels future scheduled calls, and supports undo" do
    travel_to Time.zone.local(2026, 10, 20, 10, 0) do
      lead = Lead.create!(name: "Unsure Three Voicemails", email: "unsure-3vm@example.com")
      lead.mark_unsure!
      CallLog.record!(lead, key: "req-vm-1", occurred_at: 3.days.ago, outcome: "voicemail", direction: "outbound")
      CallLog.record!(lead, key: "req-vm-2", occurred_at: 2.days.ago, outcome: "voicemail", direction: "outbound")
      due_call = lead.scheduled_calls.create!(scheduled_at: Time.zone.local(2026, 10, 20, 9, 0))
      future_call = lead.scheduled_calls.create!(scheduled_at: Time.zone.local(2026, 10, 25, 11, 0))

      2.times do
        post lead_calls_path(lead), params: { save_key: "req-vm-3", outcome: "voicemail", direction: "outbound" }
      end
      assert_redirected_to lead_path(lead, anchor: "record-details")
      assert_equal "Call logged: Voicemail.", flash[:notice]

      lead.reload
      assert lead.not_interested?
      assert_not lead.unsure?
      assert_equal [ "completed", "voicemail" ], [ due_call.reload.status, due_call.outcome ]
      assert_equal "cancelled", future_call.reload.status
      assert_equal 1, lead.activity_events.where(kind: "not_interested").count

      get lead_path(lead)
      assert_response :success
      assert_select "[role=alert][aria-label='Not interested warning']", text: /Not interested - do not contact/
      assert_select ".timeline", text: /Moved to Not interested automatically after three voicemails/
      assert_select "button", text: "Interested again"

      patch unmark_not_interested_lead_path(lead), params: { return_to: leads_path(tab: "not_interested") }
      assert_redirected_to leads_path(tab: "not_interested")
      assert_equal "Interested again - moved to Unsure.", flash[:notice]
      assert lead.reload.unsure?
      assert_not lead.not_interested?
    end
  end
end
