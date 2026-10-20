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

  test "opening Schedule call keeps row and header layouts intact on desktop and clears phone overlays" do
    second_lead = Lead.create!(name: "Deborah Garjian", email: "deborah@example.com", last_activity_at: 2.hours.ago)
    second_lead.mark_potential!

    first_lead = Lead.create!(name: "Madatovian Vahan", email: "madatovian@example.com", last_activity_at: 1.hour.ago)
    first_lead.mark_potential!
    first_lead.scheduled_calls.create!(scheduled_on: (Time.zone.today + 2.days).iso8601, scheduled_time: "12:00")

    page.current_window.resize_to(1400, 900)
    visit leads_path(tab: "potential")

    row_metrics = lambda do |name|
      page.evaluate_script(<<~JS)
        (() => {
          const row = Array.from(document.querySelectorAll("li")).find(li => li.textContent.includes(#{name.to_json}));
          const link = row.querySelector("a").getBoundingClientRect();
          const summary = row.querySelector(".call-schedule-pop > summary").getBoundingClientRect();
          const rowRect = row.getBoundingClientRect();
          return {
            rowHeight: Math.round(rowRect.height),
            linkTop: Math.round(link.top - rowRect.top),
            summaryLeft: Math.round(summary.left),
            summaryTop: Math.round(summary.top - rowRect.top)
          };
        })()
      JS
    end

    before_metrics = row_metrics.call("Deborah Garjian")
    within("li", text: "Deborah Garjian") do
      find("summary", text: "Schedule call").click
      assert_selector ".call-schedule-sheet", visible: true
    end
    after_metrics = row_metrics.call("Deborah Garjian")

    assert_equal before_metrics["rowHeight"], after_metrics["rowHeight"],
      "Opening Schedule call on desktop must not expand the Potential lead row height"
    assert_equal before_metrics["linkTop"], after_metrics["linkTop"],
      "Opening Schedule call on desktop must not shift the lead name vertically"
    assert_equal before_metrics["summaryLeft"], after_metrics["summaryLeft"],
      "Opening Schedule call on desktop must not jump the trigger button horizontally"

    sheet_bounds = open_sheet_bounds(max_bottom: 900)
    assert_operator sheet_bounds["left"], :>=, 8
    assert_operator sheet_bounds["right"], :<=, 1392
    assert_operator sheet_bounds["bottom"], :<=, 900
    assert_operator sheet_bounds["width"], :>=, 360

    # The open sheet can cover the other row's trigger, so reach it by keyboard.
    within("li", text: "Madatovian Vahan") do
      find("summary", text: "Reschedule").send_keys(:enter)
    end
    assert_selector ".call-schedule-pop[open]", count: 1

    visit lead_path(second_lead)
    heading_before = page.evaluate_script("Math.round(document.querySelector('h1').getBoundingClientRect().height)")
    heading_width_before = page.evaluate_script("Math.round(document.querySelector('h1').getBoundingClientRect().width)")
    assert_operator heading_before, :<=, 60, "Lead heading wrapped across lines before opening Schedule call"
    assert_operator heading_width_before, :>=, 200
    actions_gap = page.evaluate_script(<<~JS)
      Math.round(document.querySelector(".page-header").getBoundingClientRect().right - document.querySelector(".page-header .page-actions").getBoundingClientRect().right)
    JS
    assert_operator actions_gap.abs, :<=, 1, "Lead page actions must sit at the right edge of the header"

    within(".page-actions") do
      find("summary", text: "Schedule call").click
      assert_selector ".call-schedule-sheet", visible: true
    end
    heading_after = page.evaluate_script("Math.round(document.querySelector('h1').getBoundingClientRect().height)")
    heading_width_after = page.evaluate_script("Math.round(document.querySelector('h1').getBoundingClientRect().width)")
    assert_equal heading_before, heading_after, "Opening Schedule call in page header crushed or wrapped the lead h1"
    assert_equal heading_width_before, heading_width_after

    page.current_window.resize_to(390, 844)
    visit lead_path(second_lead)
    assert_selector ".reply-pill", visible: true
    within(".page-actions") do
      find("summary", text: "Schedule call").click
      assert_selector ".call-schedule-sheet", visible: true
    end
    assert_no_selector ".reply-pill", visible: true
    phone_sheet_bottom = open_sheet_bounds(max_bottom: 781)["bottom"]
    assert_operator phone_sheet_bottom, :<=, 781, "Phone schedule sheet should scroll above the bottom navigation bar"
  end

  test "a phone Reschedule form taller than the screen keeps its title below the top bar and scrolls inside" do
    lead = Lead.create!(name: "Madatovian Vahan", email: "madatovian@example.com", last_activity_at: 1.hour.ago)
    lead.mark_potential!
    lead.scheduled_calls.create!(scheduled_on: (Time.zone.today + 2.days).iso8601, scheduled_time: "12:00")

    %w[paper night].each do |appearance|
      Setting.current.update!(appearance: appearance)
      page.current_window.resize_to(390, 844)
      visit leads_path(tab: "potential")
      assert_selector "html[data-scheme=#{appearance}]"
      within("li", text: "Madatovian Vahan") do
        find("summary", text: "Reschedule").click
        assert_selector ".call-schedule-sheet", visible: true
      end

      layout = settled_layout(<<~JS) { |l| l["summaryTop"] >= l["headerBottom"] && l["sheetBottom"] <= l["tabbarTop"] }
        (() => {
          const pop = document.querySelector(".call-schedule-pop[open]");
          const sheet = pop.querySelector(".call-schedule-sheet");
          const submit = sheet.querySelector("[type=submit]");
          const top = { summary: pop.querySelector("summary").getBoundingClientRect().top, title: sheet.querySelector(".call-schedule-title").getBoundingClientRect().top };
          sheet.scrollTop = sheet.scrollHeight;
          const sheetRect = sheet.getBoundingClientRect();
          const submitRect = submit.getBoundingClientRect();
          return {
            headerBottom: Math.round(document.querySelector("header.sticky").getBoundingClientRect().bottom),
            tabbarTop: Math.round(document.querySelector(".tabbar").getBoundingClientRect().top),
            summaryTop: Math.round(top.summary),
            titleTop: Math.round(top.title),
            sheetBottom: Math.round(sheetRect.bottom),
            submitTop: Math.round(submitRect.top),
            submitBottom: Math.round(submitRect.bottom),
            scrollsInside: sheet.scrollHeight > sheet.clientHeight
          };
        })()
      JS
      assert_operator layout["summaryTop"], :>=, layout["headerBottom"], "Reschedule trigger is under the #{appearance} top bar: #{layout.inspect}"
      assert_operator layout["titleTop"], :>=, layout["headerBottom"], "Form title is under the #{appearance} top bar: #{layout.inspect}"
      assert_operator layout["sheetBottom"], :<=, layout["tabbarTop"], "Form runs under the #{appearance} tab bar: #{layout.inspect}"
      assert layout["scrollsInside"], "The #{appearance} form taller than the space between the bars must scroll inside: #{layout.inspect}"
      assert_operator layout["submitTop"], :>=, layout["headerBottom"], "Submit is not reachable in #{appearance}: #{layout.inspect}"
      assert_operator layout["submitBottom"], :<=, layout["sheetBottom"], "Submit is not reachable in #{appearance}: #{layout.inspect}"
    end
  end

  test "an open Schedule call sheet scrolls under the sticky top bar below desktop width" do
    16.times do |i|
      Lead.create!(name: "Potential Lead #{i}", email: "potential#{i}@example.com", last_activity_at: (i + 1).hours.ago).mark_potential!
    end

    page.current_window.resize_to(900, 700)
    visit leads_path(tab: "potential")
    first("summary", text: "Schedule call").click
    assert_selector ".call-schedule-pop[open] .call-schedule-sheet", visible: true

    covered = page.evaluate_script(<<~JS)
      (() => {
        const header = document.querySelector("header.sticky");
        const sheet = document.querySelector(".call-schedule-pop[open] .call-schedule-sheet");
        window.scrollBy(0, sheet.getBoundingClientRect().top + 20 - header.getBoundingClientRect().bottom);
        const headerRect = header.getBoundingClientRect();
        const sheetRect = sheet.getBoundingClientRect();
        const x = Math.round((sheetRect.left + sheetRect.right) / 2);
        const y = Math.round(headerRect.bottom - 4);
        return {
          overlaps: sheetRect.top < y && sheetRect.bottom > y && sheetRect.left < x && sheetRect.right > x,
          headerOnTop: header.contains(document.elementFromPoint(x, y))
        };
      })()
    JS
    assert covered["overlaps"], "Test setup should scroll the open sheet under the sticky top bar"
    assert covered["headerOnTop"], "Open Schedule call sheet must not paint over the sticky top bar"
  end

  test "Schedule call on the last Potential row stays inside the page on desktop" do
    8.times do |i|
      Lead.create!(name: "Potential Lead #{i}", email: "potential#{i}@example.com", last_activity_at: (i + 1).hours.ago).mark_potential!
    end

    page.current_window.resize_to(1400, 900)
    visit leads_path(tab: "potential")
    within(all("li", text: "Potential Lead").last) do
      find("summary", text: "Schedule call").click
      assert_selector ".call-schedule-sheet", visible: true
    end

    layout = settled_layout(<<~JS) { |l| l["sheetBottom"] <= l["viewportHeight"] - 16 }
      (() => {
        const sheet = document.querySelector(".call-schedule-pop[open] .call-schedule-sheet").getBoundingClientRect();
        return {
          railBottom: Math.round(document.querySelector("aside.rail").getBoundingClientRect().bottom),
          sheetTop: Math.round(sheet.top),
          sheetBottom: Math.round(sheet.bottom),
          viewportHeight: window.innerHeight,
          scrollY: Math.round(window.scrollY),
          maxScroll: document.documentElement.scrollHeight - window.innerHeight
        };
      })()
    JS
    assert_equal layout["viewportHeight"], layout["railBottom"], "The rail must still reach the bottom of the window: #{layout.inspect}"
    assert_operator layout["sheetTop"], :>=, 16, "Schedule call sheet must start inside the window: #{layout.inspect}"
    assert_operator layout["sheetBottom"], :<=, layout["viewportHeight"] - 16, "Schedule call sheet must keep a margin above the window bottom: #{layout.inspect}"
  end

  private
    # The sheet is positioned from the async details toggle event, so retry the
    # measurement until it settles, then return the last one for the assertions.
    def settled_layout(script)
      layout = nil
      page.document.synchronize do
        layout = page.evaluate_script(script)
        raise Capybara::ExpectationNotMet, "Schedule call sheet has not settled yet" unless yield(layout)
      end
      layout
    rescue Capybara::ExpectationNotMet
      layout
    end

    def open_sheet_bounds(max_bottom:)
      bounds = nil
      page.document.synchronize do
        bounds = page.evaluate_script(<<~JS)
          (() => {
            const r = document.querySelector(".call-schedule-pop[open] .call-schedule-sheet").getBoundingClientRect();
            return { left: Math.round(r.left), right: Math.round(r.right), bottom: Math.round(r.bottom), width: Math.round(r.width) };
          })()
        JS
        raise Capybara::ExpectationNotMet, "Schedule call sheet has not scrolled into view yet" if bounds["bottom"] > max_bottom
      end
      bounds
    end
end
