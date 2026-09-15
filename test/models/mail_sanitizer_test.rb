require "test_helper"

class SanitizerTest < ActiveSupport::TestCase
  test "strips scripts and event handlers but keeps formatting" do
    html = '<p>Hello <strong>world</strong></p><script>alert(1)</script><a href="https://example.com" onclick="evil()">link</a>'
    cleaned = Mail::Sanitizer.clean(html)
    assert_includes cleaned, "<strong>world</strong>"
    assert_not_includes cleaned, "<script"
    assert_not_includes cleaned, "onclick"
    assert_includes cleaned, 'href="https://example.com"'
  end

  test "forces links to open safely" do
    cleaned = Mail::Sanitizer.clean('<a href="https://example.com">x</a>')
    assert_includes cleaned, 'target="_blank"'
    assert_includes cleaned, 'rel="noopener"'
  end

  test "blank returns empty" do
    assert_equal "", Mail::Sanitizer.clean(nil)
    assert_equal "", Mail::Sanitizer.clean("")
  end
end
