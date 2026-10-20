require "application_system_test_case"
require_relative "../support/google_sign_in_test_helper"
require_relative "../support/inquiry_mail_test_helper"

# Today is the first screen on the phone: two tiles over one full-width tile, check rows
# completable with one tap, and no sideways scrolling at 390px.
class TodaySystemTest < ApplicationSystemTestCase
  include GoogleSignInTestHelper
  include InquiryMailTestHelper

  test "today at 390px shows the three counts tiles and safety-net banner without overflow" do
    Client.create!(name: "Maya", email: "maya@example.com")
    ingest_inquiry(subject: "New inquiry from Pemba Sherpa: Annapurna Circuit Trek")
    InquirySafetyNetJob.perform_now

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

    assert_no_selector "[aria-label='Unlinked inquiries']"
    within("[aria-label='Added to New from email']") do
      assert_text "Added to New from email: 1 · Review"
      find("summary").click
      assert_link "New inquiry from Pemba Sherpa: Annapurna Circuit Trek"
    end

    %w[not-yet-called].each do |section|
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
    assert_selector "section[aria-labelledby='replies-heading']"

    within("section[aria-label=Counts]") do
      assert_selector ".stat", count: 3
    end
    rows = page.evaluate_script(<<~JS)
      (() => {
        const grid = document.querySelector('section[aria-label=Counts] > div').getBoundingClientRect();
        const rows = {};
        document.querySelectorAll('section[aria-label=Counts] .stat').forEach(tile => {
          const box = tile.getBoundingClientRect();
          (rows[Math.round(box.top)] ||= []).push(box);
        });
        return Object.values(rows).map(row => Math.round(row[row.length - 1].right - row[0].left) === Math.round(grid.width));
      })()
    JS
    assert_equal [ true, true ], rows, "Counts tiles leave a partly filled row at 390px"
    width = page.evaluate_script("document.documentElement.scrollWidth")
    assert_operator width, :<=, 390, "Today overflows a 390px viewport (#{width}px)"
  end
end
