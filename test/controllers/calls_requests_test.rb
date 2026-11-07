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

  test "logging a third unanswered call via the one-tap endpoint moves an Unsure lead to Not interested, completes due scheduled calls, cancels future scheduled calls, and supports undo" do
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
      assert_equal "Call logged: Voicemail. Moved to Not interested after three unanswered calls.", flash[:notice]

      lead.reload
      assert lead.not_interested?
      assert_not lead.unsure?
      assert_equal [ "completed", "voicemail" ], [ due_call.reload.status, due_call.outcome ]
      assert_equal "cancelled", future_call.reload.status
      assert_equal 1, lead.activity_events.where(kind: "not_interested").count

      get lead_path(lead)
      assert_response :success
      assert_select "[role=alert][aria-label='Not interested warning']", text: /Not interested - do not contact/
      assert_select ".timeline", text: /Moved to Not interested automatically after three unanswered calls/
      assert_select "button", text: "Interested again"

      patch unmark_not_interested_lead_path(lead), params: { return_to: leads_path(tab: "not_interested") }
      assert_redirected_to leads_path(tab: "not_interested")
      assert_equal "Interested again - moved to Unsure.", flash[:notice]
      assert lead.reload.unsure?
      assert_not lead.not_interested?
    end
  end

  test "the Today call row says when a third unanswered call (Voicemail or No answer) moved the lead to Not interested" do
    lead = Lead.create!(name: "Today Three Calls", email: "today-3vm@example.com", phone: "+14155550199")
    lead.mark_unsure!
    CallLog.record!(lead, key: "today-vm-1", occurred_at: 2.days.ago, outcome: "voicemail", direction: "outbound")

    post lead_calls_path(lead), params: { save_key: "today-vm-2", outcome: "voicemail", direction: "outbound", return_to: root_path }
    assert_redirected_to root_path
    assert_equal "Call logged: Voicemail.", flash[:notice]

    post lead_calls_path(lead), params: { save_key: "today-na-3", outcome: "no_answer", direction: "outbound", return_to: root_path }
    assert_redirected_to root_path
    assert_equal "Call logged: No answer. Moved to Not interested after three unanswered calls.", flash[:notice]
    assert lead.reload.not_interested?
  end

  test "a third unanswered call moves an Unsure ad lead to Re-contact, keeps its booked calls, and supports undo" do
    travel_to Time.zone.local(2026, 10, 20, 10, 0) do
      lead = Lead.create!(name: "Unsure Ad Lead", email: "unsure-ad@example.com", source: "meta_ads")
      lead.mark_unsure!
      CallLog.record!(lead, key: "ad-vm-1", occurred_at: 3.days.ago, outcome: "voicemail", direction: "outbound")
      CallLog.record!(lead, key: "ad-vm-2", occurred_at: 2.days.ago, outcome: "no_answer", direction: "outbound")
      due_call = lead.scheduled_calls.create!(scheduled_at: Time.zone.local(2026, 10, 20, 9, 0))
      future_call = lead.scheduled_calls.create!(scheduled_at: Time.zone.local(2026, 10, 25, 11, 0))

      2.times do
        post lead_calls_path(lead), params: { save_key: "ad-vm-3", outcome: "voicemail", direction: "outbound" }
      end
      assert_redirected_to lead_path(lead, anchor: "record-details")
      assert_equal "Call logged: Voicemail. Moved to Re-contact after three unanswered calls.", flash[:notice]

      lead.reload
      assert lead.recontact?
      assert_not lead.unsure?
      assert_not lead.not_interested?
      assert_equal Date.new(2027, 1, 20), lead.recontact_on
      assert_equal [ "completed", "voicemail" ], [ due_call.reload.status, due_call.outcome ]
      assert_equal "scheduled", future_call.reload.status
      assert_includes ScheduledCall.visible, future_call
      assert_equal 1, lead.activity_events.where(kind: "recontact").count
      assert_equal 0, lead.activity_events.where(kind: "not_interested").count

      get lead_path(lead)
      assert_response :success
      assert_select "[role=region][aria-label='Re-contact list']", text: /Re-contact list/
      assert_select ".timeline", text: /Moved to Re-contact automatically after three unanswered calls/
      assert_select "[data-missed-call-reminder]", text: /3 unanswered attempts logged · on the Re-contact list for Jan 20/
      assert_select "button", text: "Restore from Re-contact"

      patch unmark_recontact_lead_path(lead), params: { return_to: leads_path(tab: "recontact") }
      assert_redirected_to leads_path(tab: "recontact")
      assert_equal "Restored from Re-contact - moved to Unsure.", flash[:notice]
      assert lead.reload.unsure?
      assert_not lead.recontact?
      assert_equal "scheduled", future_call.reload.status
    end
  end

  test "three unanswered calls move a New ad lead to Re-contact but leave a New non-ad lead in New" do
    ad = Lead.create!(name: "New Ad Lead", email: "new-ad@example.com", phone: "+14155550181", source: "google_ads")
    plain = Lead.create!(name: "New Web Lead", email: "new-web@example.com", phone: "+14155550182", source: "website_form")
    [ ad, plain ].each do |lead|
      CallLog.record!(lead, key: "new-#{lead.id}-call-1", occurred_at: 2.days.ago, outcome: "no_answer", direction: "outbound")
      CallLog.record!(lead, key: "new-#{lead.id}-call-2", occurred_at: 1.day.ago, outcome: "voicemail", direction: "outbound")
      post lead_calls_path(lead), params: { save_key: "new-#{lead.id}-call-3", outcome: "no_answer", direction: "outbound" }
    end

    assert ad.reload.recontact?
    assert_not_includes Lead.in_new_tab, ad
    assert_not plain.reload.recontact?
    assert_not plain.not_interested?
    assert_includes Lead.in_new_tab, plain
    assert_equal "Call logged: No answer.", flash[:notice]
  end

  test "three unanswered calls leave a chatting ad lead in New until it is marked Unsure" do
    lead = Lead.create!(name: "Chatting Ad Lead", email: "chatting-ad@example.com", source: "meta_ads", status: "chatting")
    3.times do |i|
      CallLog.record!(lead, key: "chat-ad-call-#{i}", occurred_at: (3 - i).days.ago, outcome: "voicemail", direction: "outbound")
    end
    assert_not lead.reload.recontact?
    assert_includes Lead.in_new_tab, lead

    patch mark_unsure_lead_path(lead), params: { return_to: leads_path(tab: "new") }
    assert_redirected_to leads_path(tab: "new")
    assert_equal "Marked as Unsure - moved to Re-contact after three unanswered calls.", flash[:notice]
    assert lead.reload.recontact?

    get leads_path(tab: "recontact")
    assert_select "a", text: lead.name
    assert_select "p.card-caption", text: /Ad leads who did not answer three call attempts/
  end

  test "a connected call or a restore starts the ad lead's three-call count over" do
    lead = Lead.create!(name: "Reset Ad Lead", email: "reset-ad@example.com", source: "meta_ads")
    lead.mark_unsure!
    CallLog.record!(lead, key: "reset-call-1", occurred_at: 5.days.ago, outcome: "no_answer", direction: "outbound")
    CallLog.record!(lead, key: "reset-call-2", occurred_at: 4.days.ago, outcome: "connected", direction: "outbound")
    CallLog.record!(lead, key: "reset-call-3", occurred_at: 3.days.ago, outcome: "no_answer", direction: "outbound")
    CallLog.record!(lead, key: "reset-call-4", occurred_at: 2.days.ago, outcome: "voicemail", direction: "outbound")
    assert_not lead.reload.recontact?

    CallLog.record!(lead, key: "reset-call-5", occurred_at: 1.day.ago, outcome: "voicemail", direction: "outbound")
    assert lead.reload.recontact?

    lead.unmark_recontact!
    CallLog.record!(lead, key: "reset-call-6", occurred_at: Time.current, outcome: "no_answer", direction: "outbound")
    assert lead.reload.unsure?
    assert_not lead.recontact?
  end

  test "an existing client's ad inquiry stays put after three unanswered calls" do
    client = Client.create!(name: "VIP Client", email: "vip@example.com")
    inquiry = Lead.create!(name: "VIP Client", email: "vip@example.com", existing_client: client, source: "meta_ads")
    inquiry.mark_unsure!
    3.times do |i|
      CallLog.record!(inquiry, key: "vip-call-#{i}", occurred_at: (3 - i).days.ago, outcome: "no_answer", direction: "outbound")
    end
    assert inquiry.reload.unsure?
    assert_not inquiry.recontact?
    assert_not inquiry.not_interested?
  end

  test "a missed call on an ad lead shows a send-by-hand reminder without any drafted message and sends nothing" do
    travel_to Time.zone.local(2026, 11, 7, 9, 30) do
      lead = Lead.create!(name: "Maya Lin", email: "maya@example.com", phone: "+14155550188", source: "meta_ads",
        trip_title: "Everest Base Camp Trek")

      assert_no_difference -> { Message.count } do
        post lead_calls_path(lead), params: { save_key: "missed-1", outcome: "voicemail", direction: "outbound" }
      end
      get lead_path(lead)
      assert_response :success
      assert_select "[data-missed-call-reminder]", count: 1
      assert_select "[data-missed-call-reminder]", text: /Missed call \(Voicemail\) - send a short text by hand/
      assert_select "[data-missed-call-reminder]", text: /Attempt 1 of 3 logged · try attempt 2 next day in the afternoon/
      assert_select "[data-missed-call-reminder] textarea, [data-missed-call-reminder] input", count: 0
      assert_no_match(/Hi Maya|this is Sam from/, response.body)

      post lead_calls_path(lead), params: { save_key: "missed-2", outcome: "connected", direction: "outbound" }
      get lead_path(lead)
      assert_select "[data-missed-call-reminder]", count: 0
    end
  end

  test "a missed call on a non-ad lead shows no text reminder" do
    lead = Lead.create!(name: "Web Visitor", email: "web-visitor@example.com", phone: "+14155550187", source: "website_form")
    post lead_calls_path(lead), params: { save_key: "web-missed-1", outcome: "no_answer", direction: "outbound" }
    get lead_path(lead)
    assert_response :success
    assert_select ".calls-recent li", text: /No answer/
    assert_select "[data-missed-call-reminder]", count: 0
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
    assert_select "input[name=video_source]", minimum: 2 do |inputs|
      inputs.each do |input|
        assert_nil input["value"]
        assert_equal "240", input["maxlength"]
      end
    end
  end

  test "an over-long video answer is shortened and the call is still logged" do
    lead = Lead.create!(name: "Long Video Answer", email: "long-video@example.com")
    answer = "Everest helicopter opener " * 20
    assert_difference -> { lead.activity_events.where(kind: "call").count }, 1 do
      post lead_calls_path(lead), params: { save_key: "long-video-1", outcome: "no_answer", direction: "outbound", video_source: answer }
    end
    assert_redirected_to lead_path(lead, anchor: "record-details")
    assert_equal "Call logged: No answer.", flash[:notice]
    stored = lead.activity_events.find_by!(idempotency_key: "long-video-1").metadata["video_source"]
    assert_equal answer.strip.first(240), stored
    assert_equal stored, lead.reload.video_source
  end

  test "re-contact list supports 3 to 6 month due dates and explicit dates while never overwriting explicit Not interested" do
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

      patch mark_recontact_lead_path(lead), params: { recontact_on: Date.yesterday.iso8601 }
      assert_redirected_to lead_path(lead)
      assert_equal custom_date, lead.reload.recontact_on

      rejected = Lead.create!(name: "Explicit Reject", email: "rejected@example.com", source: "meta_ads")
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
    end
  end
end
