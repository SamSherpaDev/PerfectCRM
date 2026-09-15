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

  test "dragging between columns keeps one ghost and clears it on cancel and drop" do
    Lead.create!(name: "Dragged traveler")
    page.current_window.resize_to(1400, 900)
    visit pipeline_path
    assert_selector "article.kcard", text: "Dragged traveler"
    page.execute_script <<~JS
      const card = document.querySelector('.board [data-pipeline-target="card"]')
      const columns = document.querySelectorAll('.board [data-pipeline-target="column"]')
      card.dispatchEvent(new DragEvent('dragstart', { bubbles: true, dataTransfer: new DataTransfer() }))
      columns[1].dispatchEvent(new DragEvent('dragover', { bubbles: true, cancelable: true }))
      columns[2].dispatchEvent(new DragEvent('dragover', { bubbles: true, cancelable: true }))
    JS
    assert_selector ".kcard-ghost", count: 1
    assert_selector '[data-stage="quoted"] .kcard-ghost', count: 1
    page.execute_script "document.querySelector('.board [data-pipeline-target=card]').dispatchEvent(new DragEvent('dragend', { bubbles: true }))"
    assert_no_selector ".kcard-ghost"
    page.execute_script <<~JS
      const card = document.querySelector('.board [data-pipeline-target="card"]')
      const column = document.querySelector('.board [data-pipeline-target="column"]')
      card.dispatchEvent(new DragEvent('dragstart', { bubbles: true, dataTransfer: new DataTransfer() }))
      column.dispatchEvent(new DragEvent('dragover', { bubbles: true, cancelable: true }))
      column.dispatchEvent(new DragEvent('drop', { bubbles: true, cancelable: true }))
    JS
    assert_no_selector ".kcard-ghost"
  end

  test "suggested message copy button copies the rendered follow-up" do
    template = Template.create!(name: "Follow-up", purpose: "itinerary_follow_up",
      subject: "Your {{trip}}", body: "Hi {{first_name}}")
    lead = Lead.create!(name: "Tashi Sherpa", trip_interest: "Annapurna")
    visit lead_path(lead, template: template.id, nudge: 1)
    assert_selector "h2", text: "Suggested message"
    page.execute_script <<~JS
      Object.defineProperty(navigator, 'clipboard', { configurable: true, value: {
        writeText: async (text) => { window.copiedMessage = text }
      } })
    JS
    click_button "Copy message"
    assert_text "Message copied."
    assert_equal "Your Annapurna\n\nHi Tashi", page.evaluate_script("window.copiedMessage")
  end

  test "phone move menu reaches Lost and Won for a single card" do
    lead = Lead.create!(name: "Phone move traveler")
    page.current_window.resize_to(390, 844)
    visit pipeline_path
    within "section[aria-label='Stages']" do
      find("summary", text: "Move", exact_text: true).click
      click_link "Lost", exact: true
    end
    assert_selector "dialog[open]"
    visit pipeline_path
    within "section[aria-label='Stages']" do
      find("summary", text: "Move", exact_text: true).click
      click_link "Won", exact: true
    end
    assert_current_path lead_path(lead)
  end

  test "missing lost reason preserves the submitted form" do
    lead = Lead.create!(name: "Original traveler")
    visit edit_lead_path(lead)
    fill_in "Name", with: "Edited traveler"
    select "Lost", from: "Status"
    click_button "Save changes"
    assert_field "Name", with: "Edited traveler"
    assert_selector "select option:checked", text: "Lost"
    assert_equal "Original traveler", lead.reload.name
    assert_equal "new", lead.status
    assert_not lead.activity_events.exists?(kind: "stage_change")
  end

  test "dragging preserves every active pipeline filter" do
    referrer = Organization.create!(name: "Alpine referrals")
    lead = Lead.create!(name: "Filtered traveler", source: "referral", trip_interest: "Annapurna",
      referred_by_organization: referrer)
    Lead.create!(name: "Unrelated traveler")
    page.current_window.resize_to(1400, 900)
    visit pipeline_path(source: "referral", trip: "Annapurna", advisor: referrer.id)
    assert_selector "article.kcard", text: lead.name
    page.execute_script <<~JS
      const card = document.querySelector('.board [data-pipeline-target="card"]')
      const destination = document.querySelector('.board [data-stage="chatting"]')
      card.dispatchEvent(new DragEvent('dragstart', { bubbles: true, dataTransfer: new DataTransfer() }))
      destination.dispatchEvent(new DragEvent('dragover', { bubbles: true, cancelable: true }))
      destination.dispatchEvent(new DragEvent('drop', { bubbles: true, cancelable: true }))
    JS
    assert_text "Moved to Chatting."
    assert_equal "chatting", lead.reload.status
    assert_field "Source", with: "referral"
    assert_field "Trip", with: "Annapurna"
    assert_field "Referred by", with: referrer.id.to_s
    assert_no_selector "article.kcard", text: "Unrelated traveler"
  end

  test "source picker filters client-only sources" do
    Client.create!(name: "Returning traveler", source: "repeat")
    Client.create!(name: "Website traveler", source: "website")
    Lead.create!(name: "Manual inquiry", source: "manual")
    page.current_window.resize_to(1400, 900)
    visit pipeline_path
    select "Repeat", from: "Source"
    click_button "Filter"
    assert_selector "article.kcard", text: "Returning traveler"
    assert_no_selector "article.kcard", text: "Website traveler"
    assert_no_selector "article.kcard", text: "Manual inquiry"
    select "Website", from: "Source"
    click_button "Filter"
    assert_selector "article.kcard", text: "Website traveler"
    assert_no_selector "article.kcard", text: "Returning traveler"
  end

  private

  def assert_no_overflow(context)
    width = page.evaluate_script("document.documentElement.scrollWidth")
    assert_operator width, :<=, 390, "#{context} overflows a 390px viewport (#{width}px)"
  end
end
