require "test_helper"
require_relative "../support/google_sign_in_test_helper"

class ScheduledCallsRequestsTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper
  include GoogleSignInTestHelper

  setup do
    sign_in
    @lead = Lead.create!(name: "Pemba Dorje", email: "pemba@example.com", phone: "+14155550123")
    @lead.mark_potential!
  end

  test "scheduling from the Leads list stays on the same tab, query, and sort" do
    return_url = leads_path(tab: "potential", q: "Pemba", sort: "fit")

    assert_difference -> { @lead.scheduled_calls.count }, 1 do
      post lead_scheduled_calls_path(@lead), params: {
        return_to: return_url,
        scheduled_call: {
          scheduled_on: "2026-10-22",
          scheduled_time: "14:00",
          duration_minutes: "30",
          notes: "Gokyo Lakes itinerary"
        }
      }
    end

    assert_redirected_to return_url
    follow_redirect!
    assert_response :success
    assert_select "li", text: /Pemba Dorje/ do
      assert_select ".badge", text: /Call Oct 22, 2:00 PM PT/
    end
  end

  test "scheduling from the Lead page stays on the Lead page and shows the next scheduled call" do
    travel_to Time.zone.local(2026, 10, 20, 10, 0) do
      lead_return = lead_path(@lead, return_to: leads_path(tab: "potential"))

      post lead_scheduled_calls_path(@lead), params: {
        return_to: lead_return,
        scheduled_call: {
          scheduled_on: "2026-10-23",
          scheduled_time: "11:00",
          duration_minutes: "45",
          notes: "Compare Manaslu vs Annapurna"
        }
      }

      assert_redirected_to lead_return
      follow_redirect!
      assert_response :success
      assert_select "#scheduled-call" do
        assert_select ".badge", text: "Next call"
        assert_select "time", text: /Oct 23 · 11:00 AM PT · 45 min/
        assert_select ".scheduled-call-note", text: "Compare Manaslu vs Annapurna"
      end
    end
  end

  test "unsafe return_to falls back to the lead page" do
    post lead_scheduled_calls_path(@lead), params: {
      return_to: "https://attacker.example/steal",
      scheduled_call: {
        scheduled_on: "2026-10-23",
        scheduled_time: "11:00"
      }
    }

    assert_redirected_to lead_path(@lead)
  end

  test "rescheduling, completing, and cancelling a scheduled call work and log call outcomes to the timeline" do
    call = @lead.scheduled_calls.create!(
      scheduled_on: "2026-10-21",
      scheduled_time: "09:00",
      duration_minutes: 30,
      notes: "Initial call"
    )

    patch lead_scheduled_call_path(@lead, call), params: {
      return_to: root_path(view: "week", date: "2026-10-21"),
      scheduled_call: {
        scheduled_on: "2026-10-21",
        scheduled_time: "15:30",
        duration_minutes: "45",
        notes: "Moved to afternoon"
      }
    }
    assert_redirected_to root_path(view: "week", date: "2026-10-21")
    assert_equal Time.zone.local(2026, 10, 21, 15, 30), call.reload.scheduled_at
    assert_equal 45, call.duration_minutes
    assert_equal "Moved to afternoon", call.notes

    assert_difference -> { @lead.activity_events.where(kind: "call").count }, 1 do
      post complete_lead_scheduled_call_path(@lead, call), params: {
        outcome: "connected",
        save_key: "scheduled-complete-1",
        return_to: lead_path(@lead)
      }
    end
    assert_redirected_to lead_path(@lead)
    assert_equal "Call logged: Talked.", flash[:notice]
    assert_equal "completed", call.reload.status
    assert_equal "connected", call.outcome

    get lead_path(@lead)
    assert_select "#scheduled-call", count: 0
    assert_select ".timeline", text: /Call: Talked/

    second_call = @lead.scheduled_calls.create!(
      scheduled_on: "2026-10-25",
      scheduled_time: "10:00"
    )
    patch cancel_lead_scheduled_call_path(@lead, second_call), params: { return_to: lead_path(@lead) }
    assert_redirected_to lead_path(@lead)
    assert_equal "cancelled", second_call.reload.status
  end

  test "a stale outcome or cancel form on a closed call changes nothing" do
    call = @lead.scheduled_calls.create!(scheduled_on: "2026-10-18", scheduled_time: "09:00")
    post complete_lead_scheduled_call_path(@lead, call), params: { outcome: "connected", save_key: "first-tap-0001" }

    assert_no_difference -> { @lead.activity_events.where(kind: "call").count } do
      post complete_lead_scheduled_call_path(@lead, call), params: { outcome: "voicemail", save_key: "stale-tap-0002" }
    end
    assert_equal "This call is no longer scheduled", flash[:alert]

    patch cancel_lead_scheduled_call_path(@lead, call)
    assert_equal "This call is no longer scheduled", flash[:alert]
    assert_equal [ "completed", "connected" ], [ call.reload.status, call.outcome ]
  end

  test "a double tap on a scheduled call outcome logs once and confirms" do
    call = @lead.scheduled_calls.create!(scheduled_on: "2026-10-18", scheduled_time: "09:00")

    assert_difference -> { @lead.activity_events.where(kind: "call").count }, 1 do
      2.times { post complete_lead_scheduled_call_path(@lead, call), params: { outcome: "connected", save_key: "double-tap-0002" } }
    end
    assert_equal "Call logged: Talked.", flash[:notice]
    assert_equal "completed", call.reload.status
  end

  test "the lead page swaps its call buttons for the scheduled call bar only while the call is due" do
    travel_to Time.zone.local(2026, 10, 20, 10, 0) do
      call = @lead.scheduled_calls.create!(scheduled_at: Time.zone.local(2026, 10, 26, 10, 0))

      get lead_path(@lead)
      assert_select "form.call-choices[action=?]", lead_calls_path(@lead), count: 1
      assert_select ".calls .hint", text: /Next call/, count: 0

      call.reschedule!(scheduled_on: "2026-10-20", scheduled_time: "16:00")
      get lead_path(@lead)
      assert_select "form.call-choices[action=?]", lead_calls_path(@lead), count: 0
      assert_select ".calls .hint", text: /Next call/
    end
  end

  test "logging a call completes today's or a missed scheduled call but never a later booking" do
    travel_to Time.zone.local(2026, 10, 20, 10, 0) do
      later = @lead.scheduled_calls.create!(scheduled_at: Time.zone.local(2026, 10, 26, 10, 0))

      post lead_calls_path(@lead), params: { save_key: "inbound-call-01", outcome: "connected", direction: "inbound" }
      assert_equal "scheduled", later.reload.status

      todays = @lead.scheduled_calls.create!(scheduled_at: Time.zone.local(2026, 10, 20, 16, 0))
      post lead_calls_path(@lead), params: { save_key: "today-call-0001", outcome: "voicemail", direction: "outbound" }
      assert_equal [ "completed", "voicemail" ], [ todays.reload.status, todays.outcome ]
      assert_equal "scheduled", later.reload.status
    end
  end

  test "a double tap on the call buttons completes one scheduled call" do
    travel_to Time.zone.local(2026, 10, 20, 10, 0) do
      missed = @lead.scheduled_calls.create!(scheduled_at: Time.zone.local(2026, 10, 19, 9, 0))
      todays = @lead.scheduled_calls.create!(scheduled_at: Time.zone.local(2026, 10, 20, 9, 30))

      2.times { post lead_calls_path(@lead), params: { save_key: "double-tap-0001", outcome: "connected", direction: "outbound" } }

      assert_equal "completed", missed.reload.status
      assert_equal "scheduled", todays.reload.status
    end
  end

  test "Today shows missed, today, and upcoming calls plus week and month calendars with stepping" do
    travel_to Time.zone.local(2026, 10, 20, 10, 0) do
      missed_lead = Lead.create!(name: "Missed Mingma")
      today_lead = Lead.create!(name: "Today Tashi")
      next_week_lead = Lead.create!(name: "Next Week Nima")

      missed_lead.scheduled_calls.create!(scheduled_at: Time.zone.local(2026, 10, 19, 14, 0), notes: "Yesterday call")
      today_lead.scheduled_calls.create!(scheduled_at: Time.zone.local(2026, 10, 20, 15, 0), notes: "Afternoon call")
      next_week_lead.scheduled_calls.create!(scheduled_at: Time.zone.local(2026, 10, 28, 11, 0), notes: "Next week call")

      get root_path
      assert_response :success
      assert_select "#scheduled-calls-section" do
        assert_select "[aria-label='Missed calls']", text: /Missed Mingma/
        assert_select "[aria-label=\"Today's calls\"]", text: /Today Tashi/
        assert_select "[aria-label='Upcoming calls']", text: /Next Week Nima/
        assert_select ".badge", text: "1 upcoming"
        assert_select "[aria-label='Week calendar']" do
          assert_select "a[href=?]", lead_path(missed_lead), text: "Missed Mingma"
          assert_select "a[href=?]", lead_path(today_lead), text: "Today Tashi"
        end
        assert_select "a[aria-label='Previous week'][href=?]", root_path(view: "week", date: "2026-10-12")
        assert_select "a[aria-label='Next week'][href=?]", root_path(view: "week", date: "2026-10-26")
      end

      get root_path(view: "week", date: "2026-10-26")
      assert_response :success
      assert_select "[aria-label='Week calendar']" do
        assert_select "a[href=?]", lead_path(next_week_lead), text: "Next Week Nima"
      end

      get root_path(view: "month", date: "2026-10-20")
      assert_response :success
      assert_select "[aria-label='Month calendar']" do
        assert_select "a[href=?]", lead_path(missed_lead), text: "Missed Mingma"
        assert_select "a[href=?]", lead_path(today_lead), text: "Today Tashi"
        assert_select "a[href=?]", lead_path(next_week_lead), text: "Next Week Nima"
      end
      assert_select "a[aria-label='Previous month'][href=?]", root_path(view: "month", date: "2026-09-01")
      assert_select "a[aria-label='Next month'][href=?]", root_path(view: "month", date: "2026-11-01")
    end
  end
  test "Today's call rows load lead tags once however many calls are listed" do
    travel_to Time.zone.local(2026, 10, 20, 10, 0) do
      tag_queries = lambda do
        count = 0
        counter = ->(*, payload) { count += 1 if payload[:sql].match?(/FROM "tags"/) }
        ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { get root_path }
        assert_response :success
        count
      end

      @lead.scheduled_calls.create!(scheduled_on: "2026-10-20", scheduled_time: "15:00")
      one_row = tag_queries.call

      %w[Ang Lhakpa Nima].each_with_index do |name, i|
        lead = Lead.create!(name: "#{name} Sherpa", email: "#{name.downcase}@example.com")
        lead.mark_potential!
        lead.scheduled_calls.create!(scheduled_on: "2026-10-2#{i + 1}", scheduled_time: "11:00")
      end

      assert_equal one_row, tag_queries.call
    end
  end

  test "scheduling, rescheduling, completing, and cancelling a call for a client works across Client show, Clients index, and Today without ad conversions" do
    travel_to Time.zone.local(2026, 10, 20, 10, 0) do
      Setting.current.update!(
        meta_dataset_id: "123456789012345",
        meta_access_token: "EAAB-secret-token",
        meta_terms_accepted: true,
        google_terms_accepted: true
      )
      client = Client.create!(name: "Amara Okafor", email: "amara@example.com", phone: "+14155550144")

      assert_no_enqueued_jobs only: AdConversions::LeadJob do
        assert_difference -> { client.scheduled_calls.count }, 1 do
          post client_scheduled_calls_path(client), params: {
            return_to: client_path(client),
            scheduled_call: {
              scheduled_on: "2026-10-22",
              scheduled_time: "11:30",
              duration_minutes: "30",
              notes: "Check Lukla flight window"
            }
          }
        end
      end

      assert_redirected_to client_path(client)
      follow_redirect!
      assert_response :success
      assert_select "#scheduled-call" do
        assert_select ".badge", text: "Next call"
        assert_select "time", text: /Oct 22 · 11:30 AM PT · 30 min/
        assert_select ".scheduled-call-note", text: "Check Lukla flight window"
      end

      get clients_path
      assert_response :success
      assert_select "li", text: /Amara Okafor/ do
        assert_select ".badge", text: /Call Oct 22, 11:30 AM PT/
        assert_select "summary", text: /Reschedule/
      end

      call = client.next_scheduled_call
      patch client_scheduled_call_path(client, call), params: {
        return_to: clients_path(q: "Amara"),
        scheduled_call: {
          scheduled_on: "2026-10-20",
          scheduled_time: "15:00",
          duration_minutes: "45",
          notes: "Moved to today afternoon"
        }
      }
      assert_redirected_to clients_path(q: "Amara")
      assert_equal Time.zone.local(2026, 10, 20, 15, 0), call.reload.scheduled_at

      get root_path
      assert_response :success
      assert_select "#scheduled-calls-section" do
        assert_select "[aria-label=\"Today's calls\"] a[href=?]", client_path(client), text: "Amara Okafor"
        assert_select "[aria-label='Week calendar'] a[href=?]", client_path(client), text: "Amara Okafor"
      end

      assert_difference -> { client.activity_events.where(kind: "call").count }, 1 do
        post complete_client_scheduled_call_path(client, call), params: {
          outcome: "connected",
          save_key: "client-complete-0001",
          return_to: client_path(client)
        }
      end
      assert_redirected_to client_path(client)
      assert_equal "completed", call.reload.status

      second_call = client.scheduled_calls.create!(scheduled_on: "2026-10-25", scheduled_time: "09:00")
      patch cancel_client_scheduled_call_path(client, second_call), params: { return_to: client_path(client) }
      assert_redirected_to client_path(client)
      assert_equal "cancelled", second_call.reload.status
    end
  end
end
