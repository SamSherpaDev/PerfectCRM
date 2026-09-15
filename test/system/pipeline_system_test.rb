require "application_system_test_case"
require_relative "../support/google_sign_in_test_helper"

# The pipeline board on desktop and the stage list on the phone: move a
# card through the Move menu (the keyboard path), require a reason on
# every loss, and keep one-handed use at 390px.
class PipelineSystemTest < ApplicationSystemTestCase
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
  end

  test "keyboard move advances a card and lost needs a reason" do
    page.current_window.resize_to(1400, 900)
    Lead.create!(name: "Board Tashi", source: "website_form", status: "new",
      trip_interest: "Annapurna", expected_value_minor: 180_000)

    visit pipeline_path
    assert_selector "h1", text: "Pipeline"
    assert_selector "article.kcard", text: "Board Tashi"

    # Keyboard path: the Move menu lists every other stage.
    within "article.kcard", text: "Board Tashi" do
      find("summary", text: "Move").click
      click_link "Chatting"
    end
    assert_text "Moved to Chatting"
    assert_equal "chatting", Lead.find_by(name: "Board Tashi").status

    # Losing without a reason is refused; the sheet opens instead.
    within "article.kcard", text: "Board Tashi" do
      find("summary", text: "Move").click
      click_link "Lost"
    end
    assert_selector "dialog#lost-sheet[open]"
    within "#lost-sheet" do
      select "Price", from: "Reason"
      fill_in "Note (optional)", with: "Chose a cheaper operator"
      click_button "Mark lost"
    end
    assert_text "Moved to Lost"
    lost = Lead.find_by(name: "Board Tashi")
    assert_equal "lost", lost.status
    assert_equal "price", lost.lost_reason
  end

  test "stage list carries the phone at 390px" do
    Lead.create!(name: "Phone Pasang", source: "google_ads", status: "new",
      expected_value_minor: 320_000)
    page.current_window.resize_to(390, 844)

    visit pipeline_path
    assert_selector "h1", text: "Pipeline"
    assert_selector "section[aria-label='Stages']"
    assert_selector "summary", text: /New/
    assert_selector ".stage-count", text: "1"

    # The board grid stays hidden; the page never scrolls sideways.
    assert_no_selector ".board article.kcard"
    assert_no_overflow("pipeline at 390px")

    # Tapping the stage reveals its cards with the Move menu intact.
    # New opens by default when it holds cards; close and reopen it.
    assert_selector "article.kcard", text: "Phone Pasang"
    find("summary", text: /New/).click
    assert_no_selector "article.kcard", text: "Phone Pasang"
    find("summary", text: /New/).click
    assert_selector "article.kcard", text: "Phone Pasang"
    within "article.kcard", text: "Phone Pasang" do
      find("summary", text: "Move").click
      assert_selector "a", text: "Quoted"
    end
    assert_no_overflow("pipeline stage open at 390px")
  end

  private

  def assert_no_overflow(context)
    width = page.evaluate_script("document.documentElement.scrollWidth")
    assert_operator width, :<=, 390, "#{context} overflows a 390px viewport (#{width}px)"
  end
end
