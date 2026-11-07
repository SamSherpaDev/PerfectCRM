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
      CallLog.record!(lead, key: "ad-vm-call-1", occurred_at: 3.days.ago, outcome: "voicemail", direction: "outbound")
      CallLog.record!(lead, key: "ad-vm-call-2", occurred_at: 2.days.ago, outcome: "no_answer", direction: "outbound")
      due_call = lead.scheduled_calls.create!(scheduled_at: Time.zone.local(2026, 10, 20, 9, 0))
      future_call = lead.scheduled_calls.create!(scheduled_at: Time.zone.local(2026, 10, 25, 11, 0))

      2.times do
        post lead_calls_path(lead), params: { save_key: "ad-vm-call-3", outcome: "voicemail", direction: "outbound" }
      end
      assert_redirected_to lead_path(lead, anchor: "record-details")
      assert_equal "Call logged: Voicemail. Moved to Re-contact after three unanswered calls. Send a short text by hand. " \
        "On the Re-contact list until Jan 20, 2027.", flash[:notice]

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
      assert_select "[data-missed-call-reminder]", text: /On the Re-contact list until Jan 20, 2027/
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
    assert_select "p.card-caption", text: /Ad leads who did not answer call attempts on three different days/
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

  test "a missed call on an ad lead shows the approved text to copy and send by hand and sends nothing" do
    travel_to Time.zone.local(2026, 11, 7, 9, 30) do
      lead = Lead.create!(name: "Maya Lin", email: "maya@example.com", phone: "+14155550188", source: "meta_ads",
        trip_title: "Everest Base Camp Trek")

      assert_no_difference -> { Message.count } do
        post lead_calls_path(lead), params: { save_key: "missed-1", outcome: "voicemail", direction: "outbound" }
      end
      assert_equal "Call logged: Voicemail. Send a short text by hand. Attempt 1 of 3 logged · try attempt 2 next day in the afternoon.",
        flash[:notice]
      get lead_path(lead)
      assert_response :success
      assert_select "[data-missed-call-reminder]", count: 1
      assert_select "[data-missed-call-reminder]", text: /Missed call \(Voicemail\) - send a short text by hand/
      assert_select "[data-missed-call-reminder]", text: /Attempt 1 of 3 logged · try attempt 2 next day in the afternoon/
      assert_equal [ "Hi Maya, this is Sam at SherpaHolidays. I just tried giving you a quick call about your trip inquiry. " \
        "When is a good time for us to connect by phone, or is text easier for you?" ],
        css_select("[data-missed-call-reminder] textarea").map { |box| box.text.strip }
      assert_select "[data-missed-call-reminder] button", text: "Copy text", count: 1
      assert_select "[data-missed-call-reminder] form", count: 0

      post lead_calls_path(lead), params: { save_key: "missed-2", outcome: "connected", direction: "outbound" }
      get lead_path(lead)
      assert_select "[data-missed-call-reminder]", count: 0
    end
  end

  test "a missed call on a nameless quiz lead offers the approved text without a name" do
    travel_to Time.zone.local(2026, 11, 7, 9, 30) do
      lead = Lead.create!(name: "", phone: "+14155550189", source: "meta_ads", placement: "trip_quiz",
        metadata: { "quiz" => { "match" => {} } })
      nameless = "Hi, this is Sam at SherpaHolidays. I just tried giving you a quick call about your trip inquiry. " \
        "When is a good time for us to connect by phone, or is text easier for you?"

      assert_no_difference -> { Message.count } do
        post lead_calls_path(lead), params: { save_key: "nameless-1", outcome: "no_answer", direction: "outbound", return_to: root_path }
      end
      assert_redirected_to root_path
      assert_equal "Call logged: No answer. Send a short text by hand. Attempt 1 of 3 logged · try attempt 2 next day in the afternoon. " \
        "Suggested text: #{nameless}", flash[:notice]

      get lead_path(lead)
      assert_response :success
      assert_equal [ nameless ], css_select("[data-missed-call-reminder] textarea").map { |box| box.text.strip }
    end
  end

  test "each missed ad-lead call logged from Today flashes the text reminder and approved text with reset-aware progress" do
    text = "Suggested text: Hi Priya, this is Sam at SherpaHolidays. I just tried giving you a quick call about your trip inquiry. " \
      "When is a good time for us to connect by phone, or is text easier for you?"
    travel_to Time.zone.local(2026, 11, 2, 10, 0) do
      lead = Lead.create!(name: "Priya Shah", email: "priya@example.com", phone: "+14155550186", source: "meta_ads")
      post lead_calls_path(lead), params: { save_key: "today-ad-1", outcome: "no_answer", direction: "outbound", return_to: root_path }
      assert_redirected_to root_path
      assert_equal "Call logged: No answer. Send a short text by hand. Attempt 1 of 3 logged · try attempt 2 next day in the afternoon. #{text}",
        flash[:notice]
      follow_redirect!
      assert_includes response.body, "Send a short text by hand. Attempt 1 of 3 logged"
      assert_includes response.body, "Hi Priya, this is Sam at SherpaHolidays."

      travel 1.day + 4.hours
      post lead_calls_path(lead), params: { save_key: "today-ad-2", outcome: "connected", direction: "outbound", return_to: root_path }
      assert_equal "Call logged: Talked.", flash[:notice]
      post lead_calls_path(lead), params: { save_key: "today-ad-3", outcome: "voicemail", direction: "outbound", return_to: root_path }
      assert_equal "Call logged: Voicemail. Send a short text by hand. Attempt 1 of 3 logged · try attempt 2 next day in the morning. #{text}",
        flash[:notice]

      travel 1.day + 4.hours
      post lead_calls_path(lead), params: { save_key: "today-ad-4", outcome: "no_answer", direction: "outbound", return_to: root_path }
      assert_equal "Call logged: No answer. Send a short text by hand. Attempt 2 of 3 logged · try attempt 3 next day in the morning. #{text}",
        flash[:notice]

      travel 15.hours
      post lead_calls_path(lead), params: { save_key: "today-ad-5", outcome: "voicemail", direction: "outbound", return_to: root_path }
      assert_redirected_to root_path
      assert_equal "Call logged: Voicemail. Moved to Re-contact after three unanswered calls. Send a short text by hand. " \
        "On the Re-contact list until Feb 5, 2027. #{text}", flash[:notice]
      assert lead.reload.recontact?
    end
  end

  test "same-day redials on an ad lead count as one attempt, and misses on three different days move it to Re-contact" do
    text = "Suggested text: Hi Nima, this is Sam at SherpaHolidays. I just tried giving you a quick call about your trip inquiry. " \
      "When is a good time for us to connect by phone, or is text easier for you?"
    lead = nil
    travel_to Time.zone.local(2026, 11, 2, 9, 0) do
      lead = Lead.create!(name: "Nima Gurung", email: "nima@example.com", phone: "+14155550190", source: "meta_ads")
      %w[no_answer voicemail no_answer].each_with_index do |outcome, i|
        travel 5.minutes if i.positive?
        post lead_calls_path(lead), params: { save_key: "same-day-#{i}", outcome: outcome, direction: "outbound", return_to: root_path }
      end
      assert_equal 3, lead.activity_events.where(kind: "call").count
      assert_equal "Call logged: No answer. Send a short text by hand. Attempt 1 of 3 logged · try attempt 2 next day in the afternoon. #{text}",
        flash[:notice]
      assert_not lead.reload.recontact?
      assert_includes Lead.in_new_tab, lead
    end

    travel_to Time.zone.local(2026, 11, 3, 12, 0) do
      entry = Today::Summary.new.call_entries.find { |e| e.lead == lead }
      assert_equal [ 2, "2nd try", "afternoon" ], [ entry.attempt, entry.attempt_label, entry.suggested_window ]
      travel 1.hour
      post lead_calls_path(lead), params: { save_key: "next-day-1", outcome: "no_answer", direction: "outbound", return_to: root_path }
      assert_equal "Call logged: No answer. Send a short text by hand. Attempt 2 of 3 logged · try attempt 3 next day in the evening. #{text}",
        flash[:notice]
      assert_not lead.reload.recontact?
    end

    travel_to Time.zone.local(2026, 11, 4, 18, 0) do
      entry = Today::Summary.new.call_entries.find { |e| e.lead == lead }
      assert_equal [ 3, "3rd try", "evening" ], [ entry.attempt, entry.attempt_label, entry.suggested_window ]
      post lead_calls_path(lead), params: { save_key: "third-day-1", outcome: "voicemail", direction: "outbound", return_to: root_path }
      assert_equal "Call logged: Voicemail. Moved to Re-contact after three unanswered calls. Send a short text by hand. " \
        "On the Re-contact list until Feb 4, 2027. #{text}", flash[:notice]
      assert lead.reload.recontact?
    end
  end

  test "an Attempted call on an ad lead stays logged without using up a miss day, so Today, the text reminder, and Re-contact agree" do
    text = "Suggested text: Hi Karma, this is Sam at SherpaHolidays. I just tried giving you a quick call about your trip inquiry. " \
      "When is a good time for us to connect by phone, or is text easier for you?"
    lead = nil
    travel_to Time.zone.local(2026, 11, 2, 10, 0) do
      lead = Lead.create!(name: "Karma Dolma", email: "karma@example.com", phone: "+14155550193", source: "meta_ads")
      post lead_calls_path(lead), params: { save_key: "attempted-day-0", outcome: "voicemail", direction: "outbound", return_to: root_path }
      assert_equal "Call logged: Voicemail. Send a short text by hand. Attempt 1 of 3 logged · try attempt 2 next day in the afternoon. #{text}",
        flash[:notice]
    end

    travel_to Time.zone.local(2026, 11, 3, 15, 0) do
      post lead_calls_path(lead), params: { save_key: "attempted-day-1", outcome: "attempted", direction: "outbound", return_to: root_path }
      assert_equal "Call logged: Attempted.", flash[:notice]
      assert_not lead.reload.recontact?
      get lead_path(lead)
      assert_select ".calls-recent li", text: /Attempted/
      assert_select "[data-missed-call-reminder]", count: 0
      get root_path
      assert_select "#call_list_lead_#{lead.id}", text: /2nd try/
      assert_select "#call_list_lead_#{lead.id}", text: /Text reminder/, count: 0
      entry = Today::Summary.new.call_entries.find { |e| e.lead == lead }
      assert_equal [ 2, "2nd try", "afternoon" ], [ entry.attempt, entry.attempt_label, entry.suggested_window ]
    end

    travel_to Time.zone.local(2026, 11, 4, 14, 0) do
      post lead_calls_path(lead), params: { save_key: "attempted-day-2", outcome: "no_answer", direction: "outbound", return_to: root_path }
      assert_equal "Call logged: No answer. Send a short text by hand. Attempt 2 of 3 logged · try attempt 3 next day in the evening. #{text}",
        flash[:notice]
      assert_not lead.reload.recontact?
    end

    travel_to Time.zone.local(2026, 11, 5, 18, 0) do
      get root_path
      assert_select "#call_list_lead_#{lead.id}", text: /3rd try/
      entry = Today::Summary.new.call_entries.find { |e| e.lead == lead }
      assert_equal [ 3, "3rd try", "evening" ], [ entry.attempt, entry.attempt_label, entry.suggested_window ]
      post lead_calls_path(lead), params: { save_key: "attempted-day-3", outcome: "voicemail", direction: "outbound", return_to: root_path }
      assert_equal "Call logged: Voicemail. Moved to Re-contact after three unanswered calls. Send a short text by hand. " \
        "On the Re-contact list until Feb 5, 2027. #{text}", flash[:notice]
      assert lead.reload.recontact?
      assert_equal 4, lead.activity_events.where(kind: "call").count
    end
  end

  test "a later Talked or inbound call moves an automatic Re-contact lead back, unlike an earlier call logged late" do
    travel_to Time.zone.local(2026, 11, 7, 10, 0) do
      answered = Lead.create!(name: "Tashi Lama", email: "tashi@example.com", phone: "+14155550191", source: "meta_ads")
      answered.mark_unsure!
      called_back = Lead.create!(name: "Dawa Sherpa", email: "dawa@example.com", phone: "+14155550192", source: "meta_ads")
      [ answered, called_back ].each do |lead|
        3.times do |i|
          CallLog.record!(lead, key: "restore-#{lead.id}-#{i}", occurred_at: (3 - i).days.ago, outcome: "no_answer", direction: "outbound")
        end
        assert lead.reload.recontact?
      end

      post lead_calls_path(answered), params: { save_key: "restore-early", outcome: "connected", direction: "outbound",
        occurred_at: "2026-11-02T10:00" }
      assert_equal "Call logged: Talked.", flash[:notice]
      assert answered.reload.recontact?
      assert_equal 0, answered.activity_events.where(kind: "recontact_restored").count

      post lead_calls_path(answered), params: { save_key: "restore-talked", outcome: "connected", direction: "outbound" }
      assert_equal "Call logged: Talked.", flash[:notice]
      assert answered.reload.unsure?
      assert_not answered.recontact?
      assert_equal [ "Moved back to Unsure: they answered a call after the automatic move." ],
        answered.activity_events.where(kind: "recontact_restored").pluck(:summary)

      post lead_calls_path(called_back), params: { save_key: "restore-inbound", outcome: "voicemail", direction: "inbound" }
      assert_equal "Call logged: Voicemail.", flash[:notice]
      assert_not called_back.reload.recontact?
      assert_includes Lead.in_new_tab, called_back
      assert_equal [ "Moved back to New: they called after the automatic move." ],
        called_back.activity_events.where(kind: "recontact_restored").pluck(:summary)

      rejected = Lead.create!(name: "Pemba Tamang", email: "pemba@example.com", phone: "+14155550193", source: "website_form")
      rejected.mark_unsure!
      3.times do |i|
        CallLog.record!(rejected, key: "restore-ni-#{i}", occurred_at: (3 - i).days.ago, outcome: "voicemail", direction: "outbound")
      end
      assert rejected.reload.not_interested?
      post lead_calls_path(rejected), params: { save_key: "restore-ni-talked", outcome: "connected", direction: "outbound" }
      post lead_calls_path(rejected), params: { save_key: "restore-ni-inbound", outcome: "connected", direction: "inbound" }
      assert rejected.reload.not_interested?
    end
  end

  test "a missed follow-up on a due Re-contact lead asks for a new date or Restore and changes nothing on its own" do
    lead = nil
    travel_to Time.zone.local(2026, 8, 3, 10, 0) do
      lead = Lead.create!(name: "Ang Dorje", email: "ang@example.com", phone: "+14155550194", source: "meta_ads")
      3.times do |i|
        CallLog.record!(lead, key: "follow-#{i}", occurred_at: (3 - i).days.ago, outcome: "no_answer", direction: "outbound")
      end
      assert lead.reload.recontact?
      assert_equal Date.new(2026, 11, 3), lead.recontact_on
    end

    travel_to Time.zone.local(2026, 11, 4, 11, 0) do
      assert_includes Today::Summary.new.call_entries.map(&:lead), lead
      get lead_path(lead)
      assert_select "[aria-label='Re-contact list']", text: /follow-up due since Nov 3, 2026/
      assert_select "[data-missed-call-reminder]", count: 0

      assert_no_difference -> { lead.activity_events.where(kind: "recontact").count } do
        post lead_calls_path(lead), params: { save_key: "follow-miss", outcome: "voicemail", direction: "outbound", return_to: root_path }
      end
      assert_redirected_to root_path
      assert_equal "Call logged: Voicemail. Send a short text by hand. Re-contact follow-up missed · set a new date 3 or 6 months out " \
        "or choose Restore from Re-contact. Suggested text: Hi Ang, this is Sam at SherpaHolidays. I just tried giving you a quick " \
        "call about your trip inquiry. When is a good time for us to connect by phone, or is text easier for you?", flash[:notice]
      lead.reload
      assert lead.recontact?
      assert_equal Date.new(2026, 11, 3), lead.recontact_on
      assert_not_includes Today::Summary.new.call_entries.map(&:lead), lead
    end

    travel_to Time.zone.local(2026, 11, 6, 9, 0) do
      assert_not_includes Today::Summary.new.call_entries.map(&:lead), lead
      assert lead.reload.recontact?
      get lead_path(lead)
      assert_select "[aria-label='Re-contact list']", text: /follow-up due since Nov 3, 2026/
      assert_select "[data-missed-call-reminder]", text: /Re-contact follow-up missed · set a new date 3 or 6 months out or choose Restore from Re-contact/
      get leads_path(tab: "recontact")
      assert_select ".badge", text: "Re-contact due since Nov 3, 2026"

      patch reschedule_recontact_lead_path(lead), params: { months: 3 }
      assert_equal Date.new(2027, 2, 6), lead.reload.recontact_on
      get lead_path(lead)
      assert_select "[aria-label='Re-contact list']", text: /due Feb 6, 2027/
      assert_select "[aria-label='Re-contact list']", text: /follow-up due since/, count: 0
      assert_select "[data-missed-call-reminder]", text: /On the Re-contact list until Feb 6, 2027/
    end
  end

  test "lost, archived, converted, and existing-client ad inquiries get no text reminder or time-of-day guidance" do
    existing = nil
    travel_to Time.zone.local(2026, 11, 2, 10, 0) do
      client = Client.create!(name: "Lhakpa Sherpa", email: "lhakpa@example.com")
      existing = Lead.create!(name: "Lhakpa Sherpa", email: "lhakpa@example.com", phone: "+14155550195",
        existing_client: client, source: "meta_ads")
      lost = Lead.create!(name: "Mingma Lama", email: "mingma@example.com", phone: "+14155550196", source: "meta_ads",
        status: "lost", lost_reason: "no_reply")
      converted = Lead.create!(name: "Sonam Rai", email: "sonam@example.com", phone: "+14155550197", source: "meta_ads")
      converted_client = converted.convert_to_client!

      post lead_calls_path(existing), params: { save_key: "routine-existing", outcome: "no_answer", direction: "outbound", return_to: root_path }
      assert_equal "Call logged: No answer.", flash[:notice]
      post lead_calls_path(lost), params: { save_key: "routine-lost", outcome: "voicemail", direction: "outbound", return_to: root_path }
      assert_equal "Call logged: Voicemail.", flash[:notice]
      post client_calls_path(converted_client), params: { save_key: "routine-converted", inquiry_id: converted.id,
        outcome: "no_answer", direction: "outbound" }
      assert_equal "Call logged: No answer.", flash[:notice]
      [ lead_path(lost), client_path(client), client_path(converted_client) ].each do |path|
        get path
        assert_response :success
        assert_select ".calls-recent li", text: /No answer|Voicemail/
        assert_select "[data-missed-call-reminder]", count: 0
      end

      archived = Lead.create!(name: "Pasang Tamang", email: "pasang@example.com", phone: "+14155550198", source: "meta_ads")
      archived.archive!
      call = CallLog.record!(archived, key: "routine-archived", occurred_at: Time.current, outcome: "no_answer", direction: "outbound")
      assert_equal "Call logged: No answer.", CallLog.notice(call, with_text: true)
    end

    travel_to Time.zone.local(2026, 11, 3, 12, 0) do
      entry = Today::Summary.new.call_entries.find { |e| e.lead == existing }
      assert_equal [ 2, nil ], [ entry.attempt, entry.suggested_window ]
    end
  end

  test "a missed call on a non-ad lead shows no text reminder" do
    lead = Lead.create!(name: "Web Visitor", email: "web-visitor@example.com", phone: "+14155550187", source: "website_form")
    post lead_calls_path(lead), params: { save_key: "web-missed-1", outcome: "no_answer", direction: "outbound", return_to: root_path }
    assert_equal "Call logged: No answer.", flash[:notice]
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

    travel 1.hour
    post lead_calls_path(lead), params: { save_key: "video-call-2", outcome: "no_answer", direction: "outbound" }
    assert_equal "Call logged: No answer.", flash[:notice]
    assert_not lead.activity_events.find_by!(idempotency_key: "video-call-2").metadata.key?("video_source")
    get lead_path(lead)
    assert_select ".calls-recent li", text: /No answer/ do |items|
      items.each { |item| assert_no_match(/Video:/, item.text) }
    end
    assert_select "#record-details dd", text: "Everest vs Annapurna helicopter opener"

    travel 1.hour
    post lead_calls_path(lead), params: { save_key: "video-call-3", outcome: "connected", direction: "outbound",
      video_source: "Annapurna base camp reel" }
    get lead_path(lead)
    assert_select "#record-details dd", text: "Annapurna base camp reel"
    assert_select "#record-details dd", text: "Everest vs Annapurna helicopter opener", count: 0
    assert_select ".calls-recent li", text: /Video: Everest vs Annapurna helicopter opener/
    assert_not lead.reload.metadata.to_h.key?("video_source")
  end

  test "a one-tap call from Today's call list logs the optional video answer on that one call event" do
    travel_to Time.zone.local(2026, 11, 2, 10, 0) do
      answered = Lead.create!(name: "Row Video Traveler", email: "row-video@example.com", phone: "+14155550171", received_at: 1.hour.ago)
      skipped = Lead.create!(name: "Row Blank Traveler", email: "row-blank@example.com", phone: "+14155550172", received_at: 2.hours.ago)

      get root_path
      [ answered, skipped ].each do |lead|
        assert_select "#call_list_lead_#{lead.id} form[action=?] input[name=video_source]", lead_calls_path(lead), count: 1 do |inputs|
          assert_nil inputs.first["value"]
          assert_equal "240", inputs.first["maxlength"]
        end
      end

      assert_difference -> { answered.activity_events.where(kind: "call").count }, 1 do
        post lead_calls_path(answered), params: { save_key: "row-video-1", outcome: "connected", direction: "outbound",
          return_to: root_path, video_source: "  Annapurna sunrise reel  " }
      end
      assert_redirected_to root_path
      assert_equal "Call logged: Talked.", flash[:notice]
      assert_equal "Annapurna sunrise reel", answered.activity_events.find_by!(idempotency_key: "row-video-1").metadata["video_source"]

      post lead_calls_path(skipped), params: { save_key: "row-video-2", outcome: "no_answer", direction: "outbound",
        return_to: root_path, video_source: "" }
      assert_equal "Call logged: No answer.", flash[:notice]
      assert_not skipped.activity_events.find_by!(idempotency_key: "row-video-2").metadata.key?("video_source")

      follow_redirect!
      assert_select "#call_list_lead_#{answered.id}", count: 0
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

  test "only the automatic ad-lead move enters Re-contact, and a listed lead can move its date to 3 or 6 months" do
    travel_to Time.zone.local(2026, 11, 7, 10, 0) do
      lead = Lead.create!(name: "Recontact Window Traveler", email: "recontact@example.com", source: "meta_ads")
      lead.mark_unsure!
      web = Lead.create!(name: "Website Unsure Traveler", email: "web-unsure@example.com", source: "website_form")
      web.mark_unsure!

      get leads_path(tab: "unsure")
      assert_select "a", text: lead.name
      assert_select "button", text: "Re-contact later", count: 0
      get lead_path(web)
      assert_select "button", text: /Re-contact/, count: 0
      patch "/leads/#{web.id}/mark_recontact", params: { months: 3 }
      assert_response :not_found
      assert_not web.reload.recontact?

      patch reschedule_recontact_lead_path(web), params: { months: 6 }
      assert_redirected_to lead_path(web)
      assert_equal "Only leads on the Re-contact list can get a new re-contact date", flash[:alert]
      assert_not web.reload.recontact?
      assert_nil web.recontact_on

      3.times do |i|
        CallLog.record!(lead, key: "window-call-#{i}", occurred_at: (3 - i).days.ago, outcome: "voicemail", direction: "outbound")
      end
      assert lead.reload.recontact?
      assert_equal Date.new(2027, 2, 7), lead.recontact_on

      get lead_path(lead)
      assert_equal [ "3 months", "6 months" ],
        css_select("[aria-label='Re-contact list'] button").map(&:text).grep(/months/)
      assert_select "[aria-label='Re-contact list'] input[type=date]", count: 0

      patch reschedule_recontact_lead_path(lead), params: { months: 6, return_to: leads_path(tab: "recontact") }
      assert_redirected_to lead_path(lead, return_to: leads_path(tab: "recontact"))
      assert_equal "Re-contact date set to May 7, 2027.", flash[:notice]
      assert_equal Date.new(2027, 5, 7), lead.reload.recontact_on

      [ { months: 4 }, { months: 24 }, { recontact_on: "2027-03-15" } ].each do |params|
        patch reschedule_recontact_lead_path(lead), params: params
        assert_redirected_to lead_path(lead)
        assert_equal "Recontact on must be 3 or 6 months out", flash[:alert]
        assert_equal Date.new(2027, 5, 7), lead.reload.recontact_on, params.inspect
      end

      rejected = Lead.create!(name: "Explicit Reject", email: "rejected@example.com", source: "meta_ads")
      rejected.mark_not_interested!
      3.times do |i|
        CallLog.record!(rejected, key: "rej-call-#{i}", occurred_at: (3 - i).days.ago, outcome: "voicemail", direction: "outbound")
      end
      assert rejected.reload.not_interested?
      assert_not rejected.recontact?
    end
  end

  test "lost ad leads never enter Re-contact, and a listed lead moved to lost leaves the list and its due call" do
    travel_to Time.zone.local(2026, 8, 3, 10, 0) do
      lost = Lead.create!(name: "Lost Ad Lead", email: "lost-ad@example.com", phone: "+14155550175", source: "meta_ads",
        status: "lost", lost_reason: "no_reply")
      lost.mark_unsure!
      3.times do |i|
        CallLog.record!(lost, key: "lost-call-#{i}", occurred_at: (3 - i).days.ago, outcome: "no_answer", direction: "outbound")
      end
      assert_not lost.reload.recontact?
      assert_nil lost.recontact_marked_at

      listed = Lead.create!(name: "Listed Then Lost", email: "listed-lost@example.com", phone: "+14155550176", source: "meta_ads")
      3.times do |i|
        CallLog.record!(listed, key: "listed-call-#{i}", occurred_at: (3 - i).days.ago, outcome: "voicemail", direction: "outbound")
      end
      assert listed.reload.recontact?
      Leads::Transition.call(listed, to: "lost", lost_reason: "no_reply")
      assert_not listed.reload.recontact?
      assert_not_includes Lead.recontact, listed
    end

    travel_to Time.zone.local(2026, 11, 3, 12, 0) do
      lost_leads = [ Lead.find_by!(name: "Lost Ad Lead"), Lead.find_by!(name: "Listed Then Lost") ]
      assert_empty Today::Summary.new.call_entries.map(&:lead) & lost_leads
      get leads_path(tab: "recontact")
      lost_leads.each { |lead| assert_select "a", text: lead.name, count: 0 }
      get leads_path(tab: "archived")
      lost_leads.each { |lead| assert_select "a", text: lead.name }
    end
  end
end
