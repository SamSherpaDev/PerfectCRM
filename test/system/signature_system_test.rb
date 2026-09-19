require "application_system_test_case"
require "tmpdir"
require "pdf/reader"
require_relative "../support/google_sign_in_test_helper"

class SignatureSystemTest < ApplicationSystemTestCase
  include GoogleSignInTestHelper
  include ActiveJob::TestHelper

  test "signature preview preserves legacy identity and clears explicitly" do
    original_delivery_method = ActionMailer::Base.delivery_method
    original_file_settings = ActionMailer::Base.file_settings
    capture_dir = Dir.mktmpdir("signature-mail-", Rails.root.join("tmp"))
    ActionMailer::Base.delivery_method = :file
    ActionMailer::Base.file_settings = { location: capture_dir }
    setting = Setting.current
    legacy = '<p>Sam Sherpa<br>Sherpa Holidays<br><a href="https://sherpaholidays.com/contact">Contact us</a></p><img src="https://tracker.example/p.gif"><img src="cid:old-logo"><script>alert(1)</script>'
    setting.update_columns(email_signature: "Sam Sherpa", email_signature_html: legacy)
    sign_in_browser
    page.current_window.resize_to(1400, 1000)
    visit edit_settings_path
    attach_file "Logo", Rails.root.join("public/icon.png")
    click_button "Save email settings"
    assert_text "saved"
    assert_selector '#signature-preview a[href="https://sherpaholidays.com/contact"]', text: "Contact us"
    assert_selector "#signature-preview img", count: 1
    assert_includes setting.reload.email_signature_html, 'href="https://sherpaholidays.com/contact"'
    assert_includes setting.email_signature_html, 'src="https://tracker.example/p.gif"'
    assert page.evaluate_script("document.querySelector('#signature-preview img').complete && document.querySelector('#signature-preview img').naturalWidth > 0")
    assert_operator find("#signature-preview img").rect.width, :<=, 120
    assert_operator find("#signature-preview img").rect.height, :<=, 44
    capture("signature-legacy-desktop")
    page.current_window.resize_to(390, 844)
    capture("signature-legacy-mobile")
    assert_operator page.evaluate_script("document.documentElement.scrollWidth"), :<=, 390

    client = Client.create!(name: "Signature recipient", email: "signature@example.test")
    quote = Quote.create!(client: client, trip_name: "Everest trek", party_size: 2, valid_until: Date.current + 14)
    quote.lines.create!(kind: "custom", description: "Trek", quantity: 2, unit_minor: 150000)
    visit quote_path(quote)
    perform_enqueued_jobs(only: ActionMailer::MailDeliveryJob) do
      click_button "Send quote"
      assert_text "Quote sent"
    end
    quote_mail = captured_mail(capture_dir, client.email)
    assert_delivered_signature(quote_mail)
    fragment = Loofah.fragment(quote_mail.html_part.decoded)
    assert_equal 1, fragment.css("img").size
    assert_equal "cid:#{EmailSignature::CID}", fragment.at_css("img")["src"]
    assert_equal "Contact us", fragment.at_css('a[href="https://sherpaholidays.com/contact"]').text
    assert_equal File.binread(Rails.root.join("public/icon.png")), quote_mail.attachments.find(&:inline?).decoded
    pdf = quote_mail.attachments.find { |part| part.mime_type == "application/pdf" }
    assert_not_nil pdf
    assert_equal "quote-#{quote.reference}.pdf", pdf.filename
    assert pdf.decoded.start_with?("%PDF-"), "Delivered quote attachment must be a PDF"
    assert_includes PDF::Reader.new(StringIO.new(pdf.decoded)).pages.map(&:text).join, "Everest trek"
    if ENV["SIGNATURE_EVIDENCE_DIR"]
      File.write(File.join(ENV.fetch("SIGNATURE_EVIDENCE_DIR"), "quote.eml"), quote_mail.encoded)
    end
    visit edit_settings_path
    fill_in "Signature lines", with: "Sam Sherpa\nSherpa Holidays\nsherpaholidays.com\n<script>literal</script>"
    click_button "Save email settings"
    assert_text "saved"
    assert_selector "#signature-preview", text: "<script>literal</script>"
    assert_no_selector "#signature-preview a, #signature-preview script"
    capture("signature-plain-mobile")

    visit client_path(client)
    click_button "Reply"
    # Opening the sheet focuses the body and animates its height. Activate
    # Details by keyboard so its moving position cannot swallow the click.
    find(".reply-details > summary").send_keys(:space)
    fill_in "Subject", with: "Signature check"
    fill_in "Message", with: "Hello, here are your trip details."
    perform_enqueued_jobs(only: OutboundDeliveryJob) do
      click_button "Send"
      assert_text "Sending your reply"
    end
    message = Message.order(:id).last
    assert_equal "sent", message.reload.status
    parsed = captured_mail(capture_dir, client.email)
    assert_equal message.message_id, parsed.message_id
    assert_equal "Signature check", parsed.subject
    assert_delivered_signature(parsed)
    assert_equal 1, parsed.html_part.decoded.scan("cid:#{EmailSignature::CID}").size
    inline = parsed.attachments.find(&:inline?)
    assert_equal File.binread(Rails.root.join("public/icon.png")), inline.decoded
    assert_equal "<#{EmailSignature::CID}>", inline.content_id
    if ENV["SIGNATURE_EVIDENCE_DIR"]
      File.write(File.join(ENV.fetch("SIGNATURE_EVIDENCE_DIR"), "reply.eml"), parsed.encoded)
      html = parsed.html_part.decoded.sub("cid:#{EmailSignature::CID}", "data:image/png;base64,#{Base64.strict_encode64(inline.decoded)}")
      File.write(File.join(ENV.fetch("SIGNATURE_EVIDENCE_DIR"), "reply.html"), html)
    end

    visit edit_settings_path
    fill_in "Signature lines", with: ""
    click_button "Save email settings"
    assert_text "saved"
    visit edit_settings_path
    assert_field "Signature lines", with: ""
    assert_no_selector "#signature-preview table"
    assert_empty setting.reload.email_signature_html
    capture("signature-cleared-mobile")
  ensure
    ActionMailer::Base.delivery_method = original_delivery_method
    ActionMailer::Base.file_settings = original_file_settings
    FileUtils.remove_entry(capture_dir) if capture_dir && File.directory?(capture_dir)
    Setting.current.signature_logo.purge if Setting.current.signature_logo.attached?
  end

  private

  # Read the transport's serialized output, never a newly invoked mailer.
  # Remove it so the next send cannot pass using the previous delivery.
  def captured_mail(directory, recipient)
    files = Dir.children(directory)
    assert_equal [ recipient ], files
    path = File.join(directory, files.first)
    mail = Mail.read(path)
    File.delete(path)
    assert_equal [ recipient ], mail.to
    mail
  end

  def assert_delivered_signature(mail)
    html = Loofah.fragment(mail.html_part.decoded)
    assert_equal 1, html.text.scan("Sam Sherpa").size
    assert_equal 1, mail.text_part.decoded.scan("Sam Sherpa").size
    assert_equal 1, html.css("img").size
    inline = mail.attachments.select(&:inline?)
    assert_equal 1, inline.size
    assert_equal "cid:#{inline.first.content_id.delete_prefix('<').delete_suffix('>')}", html.at_css("img")["src"]
    assert_equal File.binread(Rails.root.join("public/icon.png")), inline.first.decoded
    assert_operator html.at_css("img")["width"].to_i, :<=, 120
    assert_operator html.at_css("img")["height"].to_i, :<=, 44
  end

  def capture(name)
    return unless ENV["SIGNATURE_EVIDENCE_DIR"]
    page.execute_script("document.querySelector('#signature-preview').scrollIntoView({block: 'center', behavior: 'instant'})")
    page.save_screenshot(File.join(ENV.fetch("SIGNATURE_EVIDENCE_DIR"), "#{name}.png"))
  end

  def sign_in_browser
    OmniAuth.config.mock_auth[:google_oauth2] = OmniAuth::AuthHash.new(
      provider: "google_oauth2", uid: "google-captain",
      extra: { id_token: JWT.encode(@claims, @key, "RS256") }
    )
    Google::Auth::IDTokens.stub(:oidc_key_source, @source) do
      visit "/auth/google_oauth2/callback"
      assert_selector "h1", text: "Today"
    end
  end
end
