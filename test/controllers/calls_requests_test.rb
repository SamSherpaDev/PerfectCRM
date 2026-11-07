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

  test "logging a third unanswered call via the one-tap endpoint moves an Unsure lead to Re-contact, completes due scheduled calls, cancels future scheduled calls, and supports undo" do
    travel_to Time.zone.local(2026, 10, 20, 10, 0) do
      lead = Lead.create!(name: "Unsure Three Voicemails", email: "unsure-3vm@example.com")
      lead.mark_unsure!
      CallLog.record!(lead, key: "req-vm-1", occurred_at: 3.days.ago, outcome: "voicemail", direction: "outbound")
      CallLog.record!(lead, key: "req-vm-2", occurred_at: 2.days.ago, outcome: "no_answer", direction: "outbound")
      due_call = lead.scheduled_calls.create!(scheduled_at: Time.zone.local(2026, 10, 20, 9, 0))
      future_call = lead.scheduled_calls.create!(scheduled_at: Time.zone.local(2026, 10, 25, 11, 0))

      2.times do
        post lead_calls_path(lead), params: { save_key: "req-vm-3", outcome: "voicemail", direction: "outbound" }
      end
      assert_redirected_to lead_path(lead, anchor: "record-details")
      assert_equal "Call logged: Voicemail. Moved to Re-contact after three unanswered calls.", flash[:notice]

      lead.reload
      assert lead.recontact?
      assert_not lead.not_interested?
      assert_not lead.unsure?
      assert_equal Date.new(2027, 1, 20), lead.recontact_on
      assert_equal [ "completed", "voicemail" ], [ due_call.reload.status, due_call.outcome ]
      assert_equal "cancelled", future_call.reload.status
      assert_equal 1, lead.activity_events.where(kind: "recontact").count

      get lead_path(lead)
      assert_response :success
      assert_select "[role=region][aria-label='Re-contact list']", text: /Re-contact list/
      assert_select ".timeline", text: /Moved to Re-contact automatically after three unanswered calls/
      assert_select "button", text: "Restore from Re-contact"

      patch unmark_recontact_lead_path(lead), params: { return_to: leads_path(tab: "recontact") }
      assert_redirected_to leads_path(tab: "recontact")
      assert_equal "Restored from Re-contact - moved to Unsure.", flash[:notice]
      assert lead.reload.unsure?
      assert_not lead.recontact?
    end
  end

  test "the Today call row says when a third unanswered call (Voicemail or No answer) moved the lead to Re-contact" do
    lead = Lead.create!(name: "Today Three Calls", email: "today-3vm@example.com", phone: "+14155550199")
    lead.mark_unsure!
    CallLog.record!(lead, key: "today-vm-1", occurred_at: 2.days.ago, outcome: "voicemail", direction: "outbound")

    post lead_calls_path(lead), params: { save_key: "today-vm-2", outcome: "voicemail", direction: "outbound", return_to: root_path }
    assert_redirected_to root_path
    assert_equal "Call logged: Voicemail.", flash[:notice]

    post lead_calls_path(lead), params: { save_key: "today-na-3", outcome: "no_answer", direction: "outbound", return_to: root_path }
    assert_redirected_to root_path
    assert_equal "Call logged: No answer. Moved to Re-contact after three unanswered calls.", flash[:notice]
    assert lead.reload.recontact?
    assert_not lead.not_interested?
  end

  test "missed outbound calls render the manual text reminder with an editable Sam-only destination-neutral draft marked awaiting approval and never auto-send" do
    travel_to Time.zone.local(2026, 11, 7, 9, 30) do
      lead = Lead.create!(name: "Maya Lin", email: "maya@example.com", phone: "+14155550188")

      assert_no_difference -> { Message.count } do
        post lead_calls_path(lead), params: { save_key: "missed-1", outcome: "voicemail", direction: "outbound" }
      end
      assert_redirected_to lead_path(lead, anchor: "record-details")

      get lead_path(lead)
      assert_response :success
      assert_select "[data-missed-call-reminder]", text: /Missed call \(Voicemail\) - send a short text by hand/
      assert_select "[data-missed-call-reminder] .badge", text: "Awaiting approval - inactive"
      assert_select "[data-missed-call-reminder]", text: /Attempt 1 of 3 logged · try attempt 2 next day in the afternoon/
      assert_select "textarea[name=missed_call_text_draft]" do |areas|
        draft = areas.first.text.strip
        assert_includes draft, "Hi Maya, this is Sam from Sherpa Holidays."
        assert_includes draft, "your trip inquiry"
        assert_no_match(/Nepal/, draft)
        assert_no_match(/promised|same business day/i, draft)
      end
    end
  end

  test "logging a call records what video got you here on the call event and lead details" do
    lead = Lead.create!(name: "Video Source Traveler", email: "video@example.com", phone: "+14155550170")

    post lead_calls_path(lead), params: {
      save_key: "video-call-1",
      outcome: "connected",
      direction: "outbound",
      video_source: "Everest vs Annapurna helicopter opener"
    }
    assert_redirected_to lead_path(lead, anchor: "record-details")
    call = lead.activity_events.find_by!(kind: "call", idempotency_key: "video-call-1")
    assert_equal "Everest vs Annapurna helicopter opener", call.metadata["video_source"]
    assert_equal "Everest vs Annapurna helicopter opener", lead.reload.video_source

    get lead_path(lead)
    assert_response :success
    assert_select ".calls-recent li", text: /Video: Everest vs Annapurna helicopter opener/
    assert_select "#record-details dt", text: "Video that got them here"
    assert_select "#record-details dd", text: "Everest vs Annapurna helicopter opener"
  end

  test "re-contact list supports 3 to 6 month due dates and explicit dates while never overwriting explicit Not interested or moving existing client inquiries" do
    travel_to Time.zone.local(2026, 11, 7, 10, 0) do
      lead = Lead.create!(name: "Recontact Window Traveler", email: "recontact@example.com")
      lead.mark_unsure!

      patch mark_recontact_lead_path(lead), params: { months: 6, return_to: leads_path(tab: "unsure") }
      assert_redirected_to leads_path(tab: "unsure")
      assert lead.reload.recontact?
      assert_equal Date.new(2027, 5, 7), lead.recontact_on

      custom_date = Date.new(2027, 3, 15)
      patch mark_recontact_lead_path(lead), params: { recontact_on: custom_date.iso8601, return_to: leads_path(tab: "recontact") }
      assert_redirected_to leads_path(tab: "recontact")
      assert_equal custom_date, lead.reload.recontact_on

      # Rejects past dates
      patch mark_recontact_lead_path(lead), params: { recontact_on: Date.yesterday.iso8601 }
      assert_redirected_to lead_path(lead)
      assert_equal custom_date, lead.reload.recontact_on

      # Explicit Not interested cannot be overwritten by mark_recontact or 3 unanswered calls
      rejected = Lead.create!(name: "Explicit Reject", email: "rejected@example.com")
      rejected.mark_not_interested!
      patch mark_recontact_lead_path(rejected)
      assert_redirected_to lead_path(rejected)
      assert rejected.reload.not_interested?
      assert_not rejected.recontact?

      3.times do |i|
        CallLog.record!(rejected, key: "rej-call-#{i}", occurred_at: (3 - i).days.ago, outcome: "voicemail", direction: "outbound")
      end
      assert rejected.reload.not_interested?
      assert_not rejected.recontact?

      # Existing client inquiry stays out of Re-contact after 3 unanswered calls unless marked Unsure
      client = Client.create!(name: "VIP Client", email: "vip@example.com")
      client_inquiry = Lead.create!(name: "VIP Client", email: "vip@example.com", existing_client: client)
      3.times do |i|
        CallLog.record!(client_inquiry, key: "vip-call-#{i}", occurred_at: (3 - i).days.ago, outcome: "no_answer", direction: "outbound")
      end
      assert_not client_inquiry.reload.recontact?
      assert_not client_inquiry.not_interested?
    end
  end
end
