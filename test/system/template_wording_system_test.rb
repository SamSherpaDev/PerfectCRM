require "application_system_test_case"
require_relative "../support/google_sign_in_test_helper"
require_relative "../../db/migrate/20260926205306_refresh_default_template_wording"
require "pdf/reader"

class TemplateWordingSystemTest < ApplicationSystemTestCase
  include GoogleSignInTestHelper
  include ActiveJob::TestHelper

  setup do
    Object.send(:remove_const, :TEMPLATES) if Object.const_defined?(:TEMPLATES)
    load Rails.root.join("db/seeds/templates.rb")
    Setting.current.update!(sender_name: "Sam Sherpa", google_review_url: "")
    Client.create!(name: "Maya Gurung", email: "maya@example.test", perfectbook_contact_id: 4242)
    PerfectBook::Booking.create!(perfectbook_id: 9001, perfectbook_contact_id: 4242,
      trip_name: "Everest Base Camp trek", status: "deposit_received", synced_at: Time.current)
    OmniAuth.config.mock_auth[:google_oauth2] = OmniAuth::AuthHash.new(
      provider: "google_oauth2", uid: "google-captain",
      extra: { id_token: JWT.encode(@claims, @key, "RS256") }
    )
    Google::Auth::IDTokens.stub(:oidc_key_source, @source) do
      visit "/auth/google_oauth2/callback"
      assert_selector "h1", text: "Today"
    end
    page.current_window.resize_to(1400, 1000)
  end

  test "review link settings validate and personalize review sends with an empty-safe warning" do
    visit edit_settings_path
    fill_in "Write-review link", with: "http://example.test/review"
    click_button "Save review link"
    assert_text "must be a full link starting with https://"
    assert_equal "", Setting.current.reload.google_review_url
    capture("review-link-invalid")

    visit merge_templates_path
    select "Review ask", from: "Template"
    fill_in "Recipients", with: "Maya Gurung <maya@example.test>"
    click_button "Preview merge"
    assert_text "Missing: google review link"
    within("[aria-label='Merged messages']") do
      assert_text "How was Everest Base Camp trek?"
      assert_text "Hi Maya,"
      assert_text "If anything could have gone better"
      assert_text "ask them to mention your name"
      assert_no_text "[missing:"
      assert_no_text "{{"
    end
    capture("review-blank-preview")
    send_review("review-blank", link: nil)

    visit edit_settings_path
    fill_in "Write-review link", with: "https://g.page/r/example/review"
    click_button "Save review link"
    assert_text "saved"
    visit edit_settings_path
    assert_field "Write-review link", with: "https://g.page/r/example/review"
    find_field("Write-review link").scroll_to(:center)
    capture("review-link-saved")

    visit edit_template_path(Template.find_by!(purpose: :review_ask))
    within("#template_preview") { assert_text "https://g.page/r/example/review" }
    capture("review-editor-desktop")
    page.current_window.resize_to(390, 844)
    assert_operator page.evaluate_script("document.documentElement.scrollWidth"), :<=, 390
    find("#template_preview").scroll_to(:top)
    capture("review-editor-mobile")
    page.current_window.resize_to(1400, 1000)
    visit merge_templates_path
    select "Review ask", from: "Template"
    fill_in "Recipients", with: "Maya Gurung <maya@example.test>"
    click_button "Preview merge"
    assert_text "https://g.page/r/example/review"
    assert_no_text "Missing: google review link"
    capture("review-configured-preview")
    send_review("review-configured", link: "https://g.page/r/example/review")
  end

  test "all eight refreshed templates render plain copy and retain traveler referrals" do
    Template.active.order(:id).each do |template|
      visit edit_template_path(template)
      within("#template_preview") do
        assert_no_text "\u2014"
        assert_no_text "Sherpa Holidays"
        assert_no_text "[missing:"
        assert_no_text "{{"
        assert_text "SherpaHolidays" if template.first_reply?
        assert_text "ask them to mention your name" if template.review_ask? || template.repeat_nudge?
      end
      capture("template-#{template.purpose}")
    end
  end

  test "upgrade refreshes untouched copy and preserves captain edits in the editor" do
    changes = RefreshDefaultTemplateWording::CHANGES
    changes.each do |name, old_subject, old_body, _, _|
      Template.find_by!(name: name).update!(subject: old_subject, body: old_body)
    end
    edited = Template.find_by!(purpose: :first_reply)
    edited.update!(subject: "My personal greeting", body: "Hi {{first_name}}, these are my own words.")
    ActiveRecord::Migration.suppress_messages { RefreshDefaultTemplateWording.new.migrate(:up) }
    visit edit_template_path(edited)
    assert_field "Subject", with: "My personal greeting"
    within("#template_preview") { assert_text "Hi Maya, these are my own words." }
    capture("upgrade-preserved-edit")
    visit edit_template_path(Template.find_by!(purpose: :review_ask))
    within("#template_preview") do
      assert_text "How was Everest Base Camp trek?"
      assert_text "leave a review on Google?"
      assert_no_text "treasure it"
    end
    capture("upgrade-refreshed-review")
  end

  test "sent quotes show SherpaHolidays in email PDF and public acceptance page" do
    quote = Quote.create!(client: Client.find_by!(email: "maya@example.test"),
      party_size: 2, valid_until: Date.current + 14)
    quote.lines.create!(kind: "custom", description: "Nepal trek", quantity: 2, unit_minor: 150000)
    visit quote_path(quote)
    perform_enqueued_jobs(only: ActionMailer::MailDeliveryJob) do
      click_button "Send quote"
      assert_text "Quote sent"
    end
    mail = ActionMailer::Base.deliveries.last
    assert_equal "SherpaHolidays <info@sherpaholidays.com>", mail[:from].value
    assert_includes mail.subject, "for Custom SherpaHolidays trip"
    assert_not_includes mail.subject, "\u2014"
    assert_includes mail.text_part.decoded, "Custom SherpaHolidays trip"
    pdf = mail.attachments.find { |part| part.mime_type == "application/pdf" }
    pdf_text = PDF::Reader.new(StringIO.new(pdf.decoded)).pages.map(&:text).join
    assert_includes pdf_text, "SherpaHolidays"
    assert_not_includes pdf_text, "Sherpa Holidays"
    if ENV["TEMPLATE_EVIDENCE_DIR"]
      File.binwrite(File.join(ENV.fetch("TEMPLATE_EVIDENCE_DIR"), "quote.pdf"), pdf.decoded)
      File.write(File.join(ENV.fetch("TEMPLATE_EVIDENCE_DIR"), "quote.eml"), mail.encoded)
    end
    visit public_quote_path(quote.reload.accept_token)
    assert_text "SherpaHolidays"
    assert_text "Custom SherpaHolidays trip"
    capture("quote-public")
  end

  private

  def send_review(name, link:)
    perform_enqueued_jobs(only: OutboundDeliveryJob) do
      click_button "Send 1 personal emails"
      assert_selector "h1", text: "Send summary"
    end
    message = GroupSend.order(:id).last.messages.first
    assert_equal "sent", message.reload.status
    mail = ActionMailer::Base.deliveries.last
    assert_equal [ "maya@example.test" ], mail.to
    assert_equal "How was Everest Base Camp trek?", mail.subject
    assert_includes mail.text_part.decoded, "Hi Maya,"
    assert_includes mail.text_part.decoded, "mention your name"
    assert_not_includes mail.text_part.decoded, "[missing:"
    assert_not_includes mail.text_part.decoded, "\u2014"
    link ? assert_includes(mail.text_part.decoded, link) : assert_not_includes(mail.text_part.decoded, "google_review_link")
    if ENV["TEMPLATE_EVIDENCE_DIR"]
      File.write(File.join(ENV.fetch("TEMPLATE_EVIDENCE_DIR"), "#{name}.eml"), mail.encoded)
    end
    visit current_path
    assert_text "1 of 1"
    capture("#{name}-sent")
  end

  def capture(name)
    return unless ENV["TEMPLATE_EVIDENCE_DIR"]
    metrics = page.driver.browser.execute_cdp("Page.getLayoutMetrics").fetch("cssContentSize")
    shot = page.driver.browser.execute_cdp("Page.captureScreenshot",
      captureBeyondViewport: true,
      clip: { x: 0, y: 0, width: metrics.fetch("width"), height: metrics.fetch("height"), scale: 1 })
    File.binwrite(File.join(ENV.fetch("TEMPLATE_EVIDENCE_DIR"), "#{name}.png"), Base64.decode64(shot.fetch("data")))
  end
end
