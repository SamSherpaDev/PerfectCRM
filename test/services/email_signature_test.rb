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

  test "only the first pasted image becomes the logo; social icons are dropped" do
    attach_logo
    @setting.update!(email_signature_html: <<~HTML)
      <p><img src="https://cdn.example/logo.png" width="150" height="60"></p>
      <p>Sam Sherpa</p>
      <p><a href="https://linkedin.com/in/sam"><img src="https://cdn.example/in.png" width="24" height="24"></a>
      <a href="https://facebook.com/sam"><img src="https://cdn.example/fb.png" width="24" height="24"></a></p>
    HTML
    images = Loofah.fragment(EmailSignature.html_for(@setting)).css("img")
    assert_equal 1, images.size
    assert_equal "cid:#{EmailSignature::CID}", images.first["src"]
    assert_equal "150", images.first["width"]
    assert_equal "60", images.first["height"]
    assert_includes EmailSignature.html_for(@setting), 'href="https://linkedin.com/in/sam"'
  end

  test "generated logo carries its natural width capped at 200, or none when unmeasured" do
    attach_logo
    @setting.update!(email_signature: "Sam Sherpa")
    blob = @setting.signature_logo.blob

    blob.update!(metadata: blob.metadata.except("width", :width))
    assert_nil Loofah.fragment(EmailSignature.html_for(@setting)).at_css("img")["width"]

    blob.update!(metadata: blob.metadata.merge(width: 120))
    assert_equal "120", Loofah.fragment(EmailSignature.html_for(@setting)).at_css("img")["width"]

    blob.update!(metadata: blob.metadata.merge(width: 800))
    assert_equal "200", Loofah.fragment(EmailSignature.html_for(@setting)).at_css("img")["width"]
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
