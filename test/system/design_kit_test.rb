require "application_system_test_case"
require_relative "../support/google_sign_in_test_helper"

# The /design kit page is the visual regression surface: every CRM component
# renders in both schemes, and the phone shell (tab bar, hidden rail) holds
# at 390px with no sideways scrolling.
class DesignKitTest < ApplicationSystemTestCase
  include GoogleSignInTestHelper

  def sign_in_through_callback
    OmniAuth.config.mock_auth[:google_oauth2] = OmniAuth::AuthHash.new(
      provider: "google_oauth2", uid: "google-captain",
      extra: { id_token: JWT.encode(@claims, @key, "RS256") }
    )
    Google::Auth::IDTokens.stub(:oidc_key_source, @source) do
      visit "/auth/google_oauth2/callback"
      assert_selector "h1", text: "Today"
    end
  end

  def assert_no_page_overflow(path)
    width = page.evaluate_script("document.documentElement.scrollWidth")
    viewport = page.evaluate_script("document.documentElement.clientWidth")
    assert_operator width, :<=, viewport, "#{path} overflows (#{width}px > #{viewport}px)"
  end

  test "kit renders the identity and every component in paper" do
    sign_in_through_callback
    page.current_window.resize_to(1400, 1000)
    visit "/design"
    assert_selector "h1", text: "Design kit"
    assert_selector "html[data-scheme=paper]"
    # Identity: mark A on the ink tile, Everest in the header.
    assert_selector "svg use[href='#sk-mark-a']", minimum: 1
    assert_selector "header.page-header svg use[href='#sk-everest']"
    # Kept drawings present; dropped ones absent.
    %w[everest bridge pass cairn stream].each do |name|
      assert_selector "svg use[href='#sk-#{name}']", minimum: 1
    end
    assert_no_selector "svg use[href='#sk-mani']"
    assert_no_selector "svg use[href='#sk-confluence']"
    # Components.
    assert_selector "ol.timeline li.ev.in .msg"
    assert_selector "ol.timeline li.ev.out .msg"
    assert_selector "ol.timeline li.ev.auto .msg"
    assert_selector ".reply .tools .chip", minimum: 3
    assert_selector ".draft .tag", text: "AI draft, yours to edit"
    assert_selector ".board .kcard", minimum: 7
    assert_selector ".board-groups .g-leads", text: "Leads"
    assert_selector ".board-groups .g-clients", text: "Clients"
    assert_selector ".stage-row .cnt"
    assert_selector ".fit .bar .bar-fill"
    assert_selector ".src"
    assert_selector "button.toggle[aria-pressed]"
    assert_selector ".sheet.floating h3", text: "Templates"
    assert_selector ".sticky-send .t"
    assert_selector ".dep label.on"
    # Thinking orbs: both states and sizes, labelled, canvas sized by JS.
    assert_selector "canvas.orb[role=img][aria-label='Composing…']", count: 2
    assert_selector "canvas.orb[role=img][aria-label='Shaping…']", count: 2
    assert_equal 4, page.evaluate_script("[...document.querySelectorAll('canvas.orb')].filter(c => c.width > 0).length")
    # Bottom tab bar exists but hides on desktop.
    assert_selector "nav.tabbar a", text: "Today"
    assert_selector "nav.tabbar a", text: "Leads"
    assert_selector "nav.tabbar a", text: "Clients"
    assert_equal "none", page.evaluate_script("getComputedStyle(document.querySelector('[data-controller=sidebar] > .tabbar')).display")
    assert_no_page_overflow "/design"
  end

  test "kit renders in night with the same kit" do
    sign_in_through_callback
    page.current_window.resize_to(1400, 1000)
    Setting.current.update!(appearance: "night")
    visit "/design"
    assert_selector "html[data-scheme=night]"
    assert_selector "h1", text: "Design kit"
    assert_selector "ol.timeline li.ev.in .msg"
    assert_selector ".board .kcard", minimum: 7
    assert_selector "canvas.orb[aria-label='Shaping…']", minimum: 1
    assert_no_page_overflow "/design"
  end

  test "phone shell shows the tab bar and hides the rail" do
    sign_in_through_callback
    page.current_window.resize_to(390, 844)
    visit "/design"
    assert_equal "grid", page.evaluate_script("getComputedStyle(document.querySelector('[data-controller=sidebar] > .tabbar')).display")
    assert_selector "nav.tabbar a", text: "Inbox"
    assert_selector "nav.tabbar button", text: "More"
    rail_right = page.evaluate_script("document.querySelector('aside').getBoundingClientRect().right")
    assert_operator rail_right, :<=, 1, "rail should hide off-canvas on the phone"
    assert_no_page_overflow "/design"
  end

  test "crm controls show a visible focus ring" do
    sign_in_through_callback
    page.current_window.resize_to(1400, 1000)
    visit "/design"
    width = page.evaluate_script(<<~JS)
      (() => {
        const el = document.querySelector("button.toggle");
        el.focus({ focusVisible: true });
        return getComputedStyle(el).outlineWidth;
      })()
    JS
    assert_equal "2px", width
  end
end
