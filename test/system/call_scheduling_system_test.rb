require "application_system_test_case"
require_relative "../support/google_sign_in_test_helper"

class CallSchedulingSystemTest < ApplicationSystemTestCase
  include GoogleSignInTestHelper

  setup do
    OmniAuth.config.mock_auth[:google_oauth2] = OmniAuth::AuthHash.new(
      provider: "google_oauth2", uid: "google-captain",
      extra: { id_token: JWT.encode(@claims, @key, "RS256") }
    )
    Google::Auth::IDTokens.stub(:oidc_key_source, @source) do
      visit "/auth/google_oauth2/callback"
      assert_selector "h1", text: "Today"
    end
    page.current_window.resize_to(1400, 900)
  end

  test "schedule call from Potential leads list, reschedule and complete on lead page, and browse Today calendar" do
    lead = Lead.create!(name: "Ang Phurba", email: "ang@example.com", phone: "+14155550199")
    lead.mark_potential!
    missed_lead = Lead.create!(name: "Pasang Lhamu", email: "pasang@example.com")
    missed_lead.mark_potential!
    missed_lead.scheduled_calls.create!(scheduled_at: 2.hours.ago, notes: "Follow up on October dates")

    visit leads_path(tab: "potential")
    assert_selector "a", text: "Ang Phurba"

    within("li", text: "Ang Phurba") do
      find("summary", text: "Schedule call").click
      click_button "Tomorrow"
      click_button "2:00 PM"
      select "45 min", from: "Duration"
      fill_in "Note (optional)", with: "Talk through Gokyo itinerary"
      tolerate_submit_navigation { click_button "Schedule call" }
    end

    tolerate_navigation_assertion { assert_text "Call scheduled with Ang Phurba" }
    assert_current_path leads_path(tab: "potential", q: "", sort: "activity")
    within("li", text: "Ang Phurba") do
      assert_text "2:00 PM PT"
    end

    visit root_path
    within("#scheduled-calls-section") do
      within("[aria-label='Missed calls']") do
        assert_selector "a", text: "Pasang Lhamu"
        assert_text "Follow up on October dates"
      end
      within("[aria-label='Week calendar']") do
        assert_selector "a", text: "Ang Phurba"
        assert_selector "a", text: "Pasang Lhamu"
      end
      click_link "Next →"
    end
    assert_selector "#call-calendar"
    within("#scheduled-calls-section") do
      click_link "← Prev"
      click_link "Month"
    end
    within("[aria-label='Month calendar']") do
      assert_selector "a", text: "Ang Phurba"
    end

    click_link "Ang Phurba", match: :first
    assert_selector "h1", text: "Ang Phurba"
    within("#scheduled-call") do
      assert_text "Next call"
      assert_text "2:00 PM PT · 45 min"
      assert_text "Talk through Gokyo itinerary"

      find("summary", text: "Reschedule").click
      click_button "4:00 PM"
      fill_in "Note (optional)", with: "Moved to 4pm Pacific"
      tolerate_submit_navigation { click_button "Save changes" }
    end

    tolerate_navigation_assertion { assert_text "Call with Ang Phurba rescheduled" }
    within("#scheduled-call") do
      assert_text "4:00 PM PT"
      assert_text "Moved to 4pm Pacific"
      tolerate_submit_navigation { click_button "Talked" }
    end

    tolerate_navigation_assertion { assert_text "Call logged: Talked." }
    assert_no_selector "#scheduled-call"
    within(".timeline") do
      assert_text "Call: Talked"
    end
  end

  test "phone 390px layout has zero horizontal overflow across Today calendar, Leads row popover, and Lead page" do
    lead = Lead.create!(name: "Mingma Sherpa", email: "mingma@example.com")
    lead.mark_potential!
    lead.scheduled_calls.create!(
      scheduled_on: (Time.zone.today + 1.day).iso8601,
      scheduled_time: "11:00",
      notes: "Phone layout check"
    )

    page.current_window.resize_to(390, 844)

    visit root_path
    assert_selector "#scheduled-calls-section"
    width = page.evaluate_script("document.documentElement.scrollWidth")
    assert_operator width, :<=, 390, "Today week calendar overflows 390px (#{width}px)"

    within("#scheduled-calls-section") do
      click_link "Month"
    end
    assert_selector "[aria-label='Month calendar']"
    width = page.evaluate_script("document.documentElement.scrollWidth")
    assert_operator width, :<=, 390, "Today month calendar overflows 390px (#{width}px)"

    visit leads_path(tab: "potential")
    within("li", text: "Mingma Sherpa") do
      trigger = find("summary", text: "Reschedule")
      assert_operator trigger.native.size.height, :>=, 44
      trigger.click
    end
    width = page.evaluate_script("document.documentElement.scrollWidth")
    assert_operator width, :<=, 390, "Leads index with open schedule form overflows 390px (#{width}px)"

    visit lead_path(lead)
    assert_selector "#scheduled-call"
    within("#scheduled-call") do
      assert_operator find_button("Talked").native.size.height, :>=, 44
      find("summary", text: "Reschedule").click
    end
    width = page.evaluate_script("document.documentElement.scrollWidth")
    assert_operator width, :<=, 390, "Lead show with open reschedule form overflows 390px (#{width}px)"
  end
  test "phone month calendar shows a tappable call count per day that opens that week" do
    lead = Lead.create!(name: "Tenzing Dorje", email: "tenzing@example.com")
    lead.mark_potential!
    day = Time.zone.today + 1.day
    lead.scheduled_calls.create!(scheduled_on: day.iso8601, scheduled_time: "10:00")
    lead.scheduled_calls.create!(scheduled_on: day.iso8601, scheduled_time: "11:30")

    page.current_window.resize_to(390, 844)
    visit root_path(view: "month", date: day.iso8601)

    within("[aria-label='Month calendar'] [data-date='#{day.iso8601}']") do
      assert_no_link "Tenzing Dorje"
      count = find_link("2 calls on #{day.strftime('%b %-d')}, open week")
      assert_equal "2", count.text
      assert_operator count.native.size.height, :>=, 44
      count.click
    end

    assert_selector "[aria-label='Week calendar'] [data-date='#{day.iso8601}']", text: "Tenzing Dorje", count: 1
    within("[aria-label='Week calendar'] [data-date='#{day.iso8601}']") do
      assert_link "Tenzing Dorje", count: 2
    end
  end

  test "month calendar marks today like the week calendar does" do
    today = Time.zone.today
    other = today.day == 1 ? today + 1.day : today - 1.day
    cell_style = lambda do |grid, day|
      page.evaluate_script(<<~JS)
        (() => { const s = getComputedStyle(document.querySelector("[aria-label='#{grid}'] [data-date='#{day.iso8601}']")); return [s.borderTopColor, s.backgroundColor] })()
      JS
    end

    visit root_path(view: "week")
    week_today = cell_style.call("Week calendar", today)
    visit root_path(view: "month")
    assert_equal week_today, cell_style.call("Month calendar", today)
    assert_not_equal cell_style.call("Month calendar", today), cell_style.call("Month calendar", other)
  end

  test "lead banner actions share one row on desktop and 44px touch targets on phone" do
    lead = Lead.create!(name: "Nima Sherpa", email: "nima@example.com")
    lead.scheduled_calls.create!(scheduled_on: (Time.zone.today + 3.days).iso8601, scheduled_time: "10:00")
    actions = [ "Talked", "Voicemail", "No answer", "Reschedule", "Cancel call" ]
    banner_boxes = lambda do
      page.evaluate_script(<<~JS)
        Array.from(document.querySelectorAll("#scheduled-call button, #scheduled-call summary"))
          .filter(el => el.offsetParent && #{actions.to_json}.includes(el.textContent.trim()))
          .map(el => { const r = el.getBoundingClientRect(); return [el.textContent.trim(), Math.round(r.top), Math.round(r.height)] })
      JS
    end

    visit lead_path(lead)
    desktop = banner_boxes.call
    assert_equal actions.sort, desktop.map(&:first).sort
    assert_equal 1, desktop.map { |_, top, _| top }.uniq.size, "Banner actions sit at different heights: #{desktop.inspect}"

    page.current_window.resize_to(390, 844)
    visit lead_path(lead)
    banner_boxes.call.each do |label, _, height|
      assert_operator height, :>=, 44, "#{label} is #{height}px tall on phone"
    end
  end
end
