require "test_helper"

class EmailSignatureTest < ActiveSupport::TestCase
  PNG_BYTES = Base64.decode64(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
  ).freeze

  setup do
    @setting = Setting.current
    @setting.update!(email_signature: "", email_signature_html: "")
  end

  teardown do
    @setting.signature_logo.purge if @setting.signature_logo.attached?
    @setting.update!(email_signature: "", email_signature_html: "")
  end

  test "text falls back to the saved lines" do
    @setting.update!(email_signature: "Sam Sherpa\nSherpa Holidays")
    assert_equal "Sam Sherpa\nSherpa Holidays", EmailSignature.text_for(@setting)
  end

  test "text derives from HTML when only HTML is supplied" do
    @setting.update!(email_signature_html: "<p>Sam Sherpa<br>Sherpa Holidays</p>")
    assert_equal "Sam Sherpa\nSherpa Holidays", EmailSignature.text_for(@setting)
  end

  test "text from Outlook markup drops spacer lines and non-breaking spaces" do
    @setting.update!(email_signature_html:
      "<p class=MsoNormal><o:p>&nbsp;</o:p></p><p>Sam&nbsp;Sherpa</p><p>Tel: +1 &amp; <b>555</b></p>")
    assert_equal "Sam Sherpa\nTel: +1 & 555", EmailSignature.text_for(@setting)
  end

  test "text breaks lines after closing blocks and table cells" do
    @setting.update!(email_signature_html:
      "<div><b>Sam Sherpa</b></div>Sherpa Holidays<table><tr><td>Tel</td><td>555</td></tr></table>")
    assert_equal "Sam Sherpa\nSherpa Holidays\nTel\n555", EmailSignature.text_for(@setting)
  end

  test "text is blank when nothing is configured" do
    assert_nil EmailSignature.text_for(@setting)
  end

  test "sanitize keeps Outlook structure and drops scripts, styles, forms, and comments" do
    html = <<~HTML
      <p style="font-size:12pt;color:#123456;font-family:&quot;Calibri&quot;,sans-serif;position:absolute">Hi</p>
      <script>alert(1)</script>
      <style>p { color: blue; }</style>
      <form action="https://evil.example"><input type="text"></form>
      <!--[if mso]><table><tr><td>conditional</td></tr></table><![endif]-->
      <a href="javascript:alert(2)">bad</a>
      <a href="https://sherpaholidays.com">good</a>
      <a href="mailto:info@sherpaholidays.com">mail</a>
      <a href="tel:+15550100">+1 555 0100</a>
    HTML
    clean = EmailSignature.sanitize(html)
    assert_includes clean, "<p"
    assert_includes clean, "font-size: 12pt"
    assert_includes clean, "color: #123456"
    assert_includes clean, "font-family: \"Calibri\",sans-serif"
    assert_not_includes clean, "position"
    assert_not_includes clean, "alert(1)"
    assert_not_includes clean, "color: blue"
    assert_not_includes clean, "<form"
    assert_not_includes clean, "conditional"
    assert_includes clean, "<a>bad</a>"
    assert_includes clean, 'href="https://sherpaholidays.com"'
    assert_includes clean, 'href="mailto:info@sherpaholidays.com"'
    assert_includes clean, 'href="tel:+15550100"'
  end

  test "sanitize drops inline styles down to font-size, font-family, and color" do
    clean = EmailSignature.sanitize(
      '<span style="background: url(https://evil.example/p.gif); color: red; font-size: 11pt">x</span>'
    )
    assert_not_includes clean, "url("
    assert_includes clean, "color: red"
    assert_includes clean, "font-size: 11pt"
  end

  test "block fits a wide logo inside 120x44" do
    attach_png(600, 200)
    @setting.update!(email_signature: "Sam Sherpa\nFounder, Sherpa Holidays")
    img = Loofah.fragment(EmailSignature.html_for(@setting)).at_css("img")
    assert_equal "cid:#{EmailSignature::CID}", img["src"]
    assert_equal "120", img["width"]
    assert_equal "40", img["height"]
    assert_equal "Sherpa Holidays", img["alt"]
  end

  test "block fits a square mark and never upscales a small one" do
    attach_png(90, 90)
    @setting.update!(email_signature: "Sam Sherpa")
    img = Loofah.fragment(EmailSignature.html_for(@setting)).at_css("img")
    assert_equal "44", img["width"]
    assert_equal "44", img["height"]

    attach_png(40, 12)
    img = Loofah.fragment(EmailSignature.html_for(@setting)).at_css("img")
    assert_equal "40", img["width"]
    assert_equal "12", img["height"]
  end

  test "logo dimensions come from header bytes when metadata is absent" do
    attach_png(600, 200)
    blob = @setting.signature_logo.blob
    blob.update!(metadata: { "identified" => true })
    assert_equal [ 600, 200 ], EmailSignature.logo_dimensions(blob)
    assert_equal [ 120, 40 ], EmailSignature.logo_box(@setting)
  end

  test "logo dimensions read GIF and JPEG headers" do
    @setting.signature_logo.attach(
      io: StringIO.new("GIF89a".b + [ 90, 90 ].pack("vv") + "\x00".b),
      filename: "logo.gif", content_type: "image/gif"
    )
    assert_equal [ 44, 44 ], EmailSignature.logo_box(@setting)
    @setting.signature_logo.purge

    sof = "\xFF\xC0".b + [ 8 ].pack("n") + "\x08".b + [ 200, 600 ].pack("nn") + "\x01\x11\x00".b
    @setting.signature_logo.attach(
      io: StringIO.new("\xFF\xD8".b + sof),
      filename: "logo.jpg", content_type: "image/jpeg"
    )
    assert_equal [ 600, 200 ], EmailSignature.logo_dimensions(@setting.signature_logo.blob)
    assert_equal [ 120, 40 ], EmailSignature.logo_box(@setting)
  end

  test "block without a logo keeps the words and the ochre rule, no image" do
    @setting.update!(email_signature: "Sam Sherpa\nFounder, Sherpa Holidays")
    html = EmailSignature.html_for(@setting)
    assert_not_includes html, "<img"
    assert_includes html, "Sam Sherpa"
    assert_includes html, "border-left:2px solid #c96f1a"
  end

  test "first line renders as the bold name, details as plain lines" do
    @setting.update!(email_signature: "Sam Sherpa\nFounder, Sherpa Holidays")
    html = EmailSignature.html_for(@setting)
    assert_includes html, "font-family:Georgia"
    assert_includes html, "font-weight:bold;\">Sam Sherpa<"
    assert_includes html, ">Founder, Sherpa Holidays<"
  end

  test "detail lines escape text without inferring link destinations" do
    @setting.update!(email_signature: [
      "Sam Sherpa",
      "sherpaholidays.com | +1 555 0100",
      "https://sherpaholidays.com/everest, info@sherpaholidays.com",
      "Sam <boss> & \"friends\""
    ].join("\n"))
    html = EmailSignature.html_for(@setting)
    assert_empty Loofah.fragment(html).css("a")
    assert_includes html, "Sam &lt;boss&gt; &amp; &quot;friends&quot;"
    assert_not_includes html, "<script"
  end

  test "legacy formatted words without an image still build the block with the logo" do
    attach_logo
    @setting.update_columns(email_signature: "", email_signature_html: "Sam Sherpa\nFounder, Sherpa Holidays")
    @setting.reload
    html = EmailSignature.html_for(@setting)
    assert_includes html, "cid:#{EmailSignature::CID}"
    assert_includes html, "Sam Sherpa"
    assert_includes html, "Founder, Sherpa Holidays"
  end

  test "saving with blank lines copies legacy words without clearing the column" do
    @setting.update_columns(email_signature: "", email_signature_html: "<p>Sam Sherpa<br>Sherpa Holidays</p>")
    @setting.reload
    @setting.save!
    assert_equal "Sam Sherpa\nSherpa Holidays", @setting.email_signature
    assert_equal "<p>Sam Sherpa<br>Sherpa Holidays</p>", @setting.email_signature_html
  end

  test "legacy images are omitted without changing stored markup or safe links" do
    legacy = '<p>Sam Sherpa</p><a href="https://sherpaholidays.com">Visit</a><img src="https://tracker.example/p.gif"><img src="cid:old-logo">'
    @setting.update_columns(email_signature_html: legacy)
    fragment = Loofah.fragment(EmailSignature.html_for(@setting.reload))
    assert_empty fragment.css("img")
    assert_includes fragment.text, "Sam Sherpa"
    assert_equal "Visit", fragment.at_css('a[href="https://sherpaholidays.com"]').text
    assert_equal legacy, @setting.reload.email_signature_html
  end

  test "html is empty when nothing is configured" do
    assert_equal "", EmailSignature.html_for(@setting)
  end

  test "split_body separates the appended signature at the end" do
    @setting.update!(email_signature: "Sam Sherpa")
    before, after = EmailSignature.split_body("Hello\n\nSam Sherpa\n")
    assert_equal "Hello", before
    assert_equal "", after
  end

  test "split_body separates the template signature inline" do
    @setting.update!(email_signature: "Sam Sherpa")
    template = Template.create!(name: "Signed", purpose: "custom", subject: "Hi", body: "Regards {{signature}}\nPS soon")
    before, after = EmailSignature.split_body("Regards Sam Sherpa\nPS soon", template_id: template.id)
    assert_equal "Regards ", before
    assert_equal "\nPS soon", after
  end

  test "split_body returns nil when the signature is absent" do
    @setting.update!(email_signature: "Sam Sherpa")
    assert_nil EmailSignature.split_body("Hello there")
  end

  private

  def attach_logo
    @setting.signature_logo.attach(
      io: StringIO.new(PNG_BYTES), filename: "logo.png", content_type: "image/png"
    )
  end

  # A minimal PNG carrying the given dimensions in its IHDR header.
  def attach_png(width, height)
    @setting.signature_logo.purge if @setting.signature_logo.attached?
    bytes = [ 0x89504E47, 0x0D0A1A0A ].pack("NN") + [ 13 ].pack("N") +
      "IHDR" + [ width, height ].pack("NN") + "\x08\x02\x00\x00\x00".b
    @setting.signature_logo.attach(
      io: StringIO.new(bytes), filename: "logo.png", content_type: "image/png"
    )
  end
end
