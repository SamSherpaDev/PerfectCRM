require "application_system_test_case"
require_relative "../support/google_sign_in_test_helper"

class OrbLifecycleTest < ApplicationSystemTestCase
  include GoogleSignInTestHelper

  test "orbs respect motion changes visibility and Turbo removal" do
    OmniAuth.config.mock_auth[:google_oauth2] = OmniAuth::AuthHash.new(
      provider: "google_oauth2", uid: "google-captain",
      extra: { id_token: JWT.encode(@claims, @key, "RS256") }
    )
    Google::Auth::IDTokens.stub(:oidc_key_source, @source) do
      visit "/auth/google_oauth2/callback"
      assert_selector "h1", text: "Today"
    end
    browser = page.driver.browser
    baseline_visibility_listeners = visibility_listener_count(browser)
    browser.execute_cdp("Emulation.setEmulatedMedia", features: [ { name: "prefers-reduced-motion", value: "reduce" } ])
    visit "/design"
    assert_selector "canvas.orb", count: 4
    page.execute_script(<<~JS)
      window.orbPaints = 0;
      window.detachedOrbPaints = 0;
      const clear = CanvasRenderingContext2D.prototype.clearRect;
      CanvasRenderingContext2D.prototype.clearRect = function(...args) {
        if (this.canvas.matches('canvas.orb')) {
          window.orbPaints++;
          if (!this.canvas.isConnected) window.detachedOrbPaints++;
        }
        return clear.apply(this, args);
      };
      document.querySelector('#kit-orbs').scrollIntoView();
    JS
    assert_equal 0, paints_over_interval
    capture("orbs-reduced-motion")
    browser.execute_cdp("Emulation.setEmulatedMedia", features: [ { name: "prefers-reduced-motion", value: "no-preference" } ])
    assert_operator paints_over_interval, :>, 0
    page.execute_script("window.scrollTo(0, 0)")
    # Allow IntersectionObserver to deliver the scroll before measuring idle work.
    settle_browser
    assert_equal 0, paints_over_interval
    page.execute_script("document.querySelector('#kit-orbs').scrollIntoView()")
    settle_browser
    assert_operator paints_over_interval, :>, 0
    page.execute_script("Turbo.visit('/')")
    assert_selector "h1", text: "Today"
    settle_browser
    assert_equal 0, paints_over_interval
    assert_equal 0, page.evaluate_script("window.detachedOrbPaints")
    assert_equal baseline_visibility_listeners, visibility_listener_count(browser)

    visit "/design"
    [ [1400, 1000, "desktop"], [390, 844, "phone"] ].each do |width, height, label|
      page.current_window.resize_to(width, height)
      %w[mark orbs timeline pipeline].each do |section|
        page.execute_script("document.querySelector(arguments[0]).scrollIntoView()", "#design-#{section}")
        capture("#{label}-#{section}")
      end
    end
  ensure
    browser&.execute_cdp("Emulation.setEmulatedMedia", features: [])
  end

  private

  def visibility_listener_count(browser)
    browser.execute_cdp("Runtime.evaluate",
      expression: "(getEventListeners(document).visibilitychange || []).length",
      includeCommandLineAPI: true).dig("result", "value")
  end

  def paints_over_interval
    page.evaluate_async_script(<<~JS)
      const done = arguments[arguments.length - 1];
      const start = window.orbPaints;
      setTimeout(() => done(window.orbPaints - start), 250);
    JS
  end

  def settle_browser
    page.evaluate_async_script("const done = arguments[arguments.length - 1]; setTimeout(done, 100)")
  end

  def capture(label)
    return unless ENV["GATE_EVIDENCE"]
    page.save_screenshot(File.join(ENV.fetch("GATE_EVIDENCE"), "#{label}.png"))
  end
end
