require "application_system_test_case"
require_relative "../support/google_sign_in_test_helper"

# Today is the first screen on the phone: two tiles per row, check rows
# completable with one tap, and no sideways scrolling at 390px.
class TodaySystemTest < ApplicationSystemTestCase
  include GoogleSignInTestHelper

  test "today at 390px completes a follow-up with one tap" do
    client = Client.create!(name: "Maya", email: "maya@example.com")
    client.tasks.create!(title: "Nudge Maya about the deposit", due_on: Date.current)

    OmniAuth.config.mock_auth[:google_oauth2] = OmniAuth::AuthHash.new(
      provider: "google_oauth2", uid: "google-captain",
      extra: { id_token: JWT.encode(@claims, @key, "RS256") }
    )
    Google::Auth::IDTokens.stub(:oidc_key_source, @source) do
      visit "/auth/google_oauth2/callback"
      assert_selector "h1", text: "Today"
    end
    page.current_window.resize_to(390, 844)
    page.evaluate_async_script("const done = arguments[0]; Promise.all(document.getAnimations().map(a => a.finished.catch(() => {}))).then(done)")

    %w[departing returned].each do |section|
      empty_state = find("section[aria-labelledby='#{section}-heading'] .empty-inline")
      overlaps = empty_state.evaluate_script(<<~JS)
        (() => {
          const text = Array.from(this.querySelectorAll('p')).flatMap(p => {
            const range = document.createRange();
            range.selectNodeContents(p);
            return Array.from(range.getClientRects());
          });
          return Array.from(this.querySelectorAll('svg')).some(svg => {
            const illustration = svg.getBoundingClientRect();
            return text.some(line => illustration.left < line.right && illustration.right > line.left &&
              illustration.top < line.bottom && illustration.bottom > line.top);
          });
        })()
      JS
      assert_not overlaps, "#{section} illustration overlaps empty-state text at 390px"
    end

    within("section[aria-label=Counts]") do
      assert_selector ".stat", count: 4
    end
    width = page.evaluate_script("document.documentElement.scrollWidth")
    assert_operator width, :<=, 390, "Today overflows a 390px viewport (#{width}px)"

    complete = find("button[aria-label='Mark done: Nudge Maya about the deposit']")
    size = complete.evaluate_script("[this.offsetWidth, this.offsetHeight]")
    assert_operator size[0], :>=, 44, "complete target is narrower than 44px"
    assert_operator size[1], :>=, 44, "complete target is shorter than 44px"
    complete.click

    assert_text "Done. Nice."
    assert_no_text "Nudge Maya about the deposit"
  end
end
