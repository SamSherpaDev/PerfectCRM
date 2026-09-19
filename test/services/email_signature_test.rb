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
      <p style="font-size:12pt;color:#123456;font-family:Evil">Hi</p>
      <script>alert(1)</script>
      <style>p { color: blue; }</style>
      <form action="https://evil.example"><input type="text"></form>
      <!--[if mso]><table><tr><td>conditional</td></tr></table><![endif]-->
      <a href="javascript:alert(2)">bad</a>
      <a href="https://sherpaholidays.com">good</a>
      <a href="mailto:info@sherpaholidays.com">mail</a>
    HTML
    clean = EmailSignature.sanitize(html)
    assert_includes clean, "<p"
    assert_includes clean, "font-size: 12pt"
    assert_includes clean, "color: #123456"
    assert_not_includes clean, "font-family"
    assert_not_includes clean, "alert(1)"
    assert_not_includes clean, "color: blue"
    assert_not_includes clean, "<form"
    assert_not_includes clean, "conditional"
    assert_includes clean, "<a>bad</a>"
    assert_includes clean, 'href="https://sherpaholidays.com"'
    assert_includes clean, 'href="mailto:info@sherpaholidays.com"'
  end

  test "sanitize drops inline styles down to font-size and color" do
    clean = EmailSignature.sanitize(
      '<span style="background: url(https://evil.example/p.gif); color: red; font-size: 11pt">x</span>'
    )
    assert_not_includes clean, "url("
    assert_includes clean, "color: red"
    assert_includes clean, "font-size: 11pt"
  end

  test "past images become the uploaded logo by Content-ID" do
    attach_logo
    @setting.update!(email_signature_html:
      '<p>Sam</p><img src="https://tracker.example/pixel.gif" width="120" height="30">')
    html = EmailSignature.html_for(@setting)
    assert_includes html, "cid:#{EmailSignature::CID}"
    assert_includes html, 'width="120"'
    assert_not_includes html, "tracker.example"
    assert_not_includes html, "http"
  end

  test "past images are dropped when no logo is attached" do
    @setting.update!(email_signature_html: "<p>Sam</p><img src=\"https://tracker.example/p.gif\">")
    html = EmailSignature.html_for(@setting)
    assert_not_includes html, "<img"
    assert_not_includes html, "tracker.example"
    assert_includes html, "Sam"
  end

  test "build-from-text escapes the lines and adds the logo" do
    attach_logo
    @setting.update!(email_signature: "Sam <boss>\nSherpa Holidays")
    html = EmailSignature.html_for(@setting)
    assert_includes html, "cid:#{EmailSignature::CID}"
    assert_includes html, "Sam &lt;boss&gt;"
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
end
