require "test_helper"

class TemplateRendererTest < ActiveSupport::TestCase
  test "substitutes every supported placeholder" do
    context = {
      first_name: "Maya", full_name: "Maya Gurung", trip: "Everest Base Camp trek",
      departure_dates: "May 4 – May 18, 2027", balance_due: "$1,850.00",
      deposit_due: "$500.00", invoice_number: "SH-2027-0142",
      payment_reference: "SH-0142-MAYA", missing_documents: "passport copy",
      advisor_name: "Adventure Co.", my_name: "Sam", signature: "Sam",
      google_review_link: "https://g.page/r/sample/review"
    }
    text = TemplateRenderer::PLACEHOLDERS.map { |name| "{{#{name}}}" }.join("|")
    rendered = TemplateRenderer.render(text, context)
    context.each_value { |value| assert_includes rendered, value }
    assert_not_includes rendered, "{{"
  end

  test "accepts string keys and ignores nil values" do
    assert_equal "Hi Maya!", TemplateRenderer.render("Hi {{first_name}}!", "first_name" => "Maya")
    assert_equal "Hi [missing: first_name]!", TemplateRenderer.render("Hi {{first_name}}!", first_name: nil)
  end

  test "unknown placeholders render as a visible missing marker, never blank" do
    assert_equal "Hello [missing: nickname], {{ left",
      TemplateRenderer.render("Hello {{nickname}}, {{ left", {})
  end

  test "render leaves values raw for plain-text mail" do
    assert_equal "A & B <3", TemplateRenderer.render("{{note}}", note: "A & B <3")
  end

  test "subjects fall back for absent, nil, empty, whitespace, and unknown placeholder values" do
    [ {}, { trip: nil }, { "trip" => "" }, { trip: " \t" } ].each do |context|
      assert_equal "Planning your trip", TemplateRenderer.render_subject("Documents for {{ trip }}", context)
    end
    assert_equal "Planning your trip", TemplateRenderer.render_subject("Hello {{nickname}}", first_name: "Tashi")
    assert_equal "Planning your trip",
      TemplateRenderer.render_subject("Hi {{first_name}}, your {{trip}}", first_name: "Tashi")
    assert_equal "Planning your trip", TemplateRenderer.render_subject("Review {{google_review_link}}", {})
  end

  test "subjects with real values and subjects without placeholders stay unchanged" do
    assert_equal "Your Annapurna trip", TemplateRenderer.render_subject("Your {{trip}} trip", trip: "Annapurna")
    assert_equal "Hi Tashi, your Annapurna trip",
      TemplateRenderer.render_subject("Hi {{first_name}}, your {{trip}} trip", "first_name" => "Tashi", "trip" => "Annapurna")
    assert_equal "Balance: 0", TemplateRenderer.render_subject("Balance: {{balance_due}}", balance_due: 0)
    assert_equal "A & B <3", TemplateRenderer.render_subject("{{trip}}", trip: "A & B <3")
    assert_equal "Hello from SherpaHolidays", TemplateRenderer.render_subject("Hello from SherpaHolidays", {})
    assert_equal "", TemplateRenderer.render_subject(nil, {})
  end

  test "subject fallback does not change body or editor preview missing markers" do
    text = "Your {{trip}}"
    assert_equal "Planning your trip", TemplateRenderer.render_subject(text, {})
    assert_equal "Your [missing: trip]", TemplateRenderer.render(text, {})
    assert_equal "Your [missing: trip]", TemplateRenderer.render_html(text, {})
  end

  test "render_html escapes values for the preview pane" do
    html = TemplateRenderer.render_html("Hi {{first_name}}", first_name: "<script>alert(1)</script>")
    assert_includes html, "&lt;script&gt;"
    assert_not_includes html, "<script>"
  end

  test "render_html escapes template text itself" do
    html = TemplateRenderer.render_html("<b>{{first_name}}</b>", first_name: "Maya")
    assert_includes html, "&lt;b&gt;Maya&lt;/b&gt;"
  end

  test "an empty optional placeholder drops its line and the gap it leaves" do
    text = "Please leave a review.\n\n{{google_review_link}}\n\nThank you,\n{{my_name}}"
    assert_equal "Please leave a review.\n\nThank you,\nSam", TemplateRenderer.render(text, my_name: "Sam")
    assert_equal "Please leave a review.\n\nThank you,\nSam",
      TemplateRenderer.render(text, my_name: "Sam", google_review_link: " ")
    assert_equal "Please leave a review.\n\nThank you,\nSam", TemplateRenderer.render_html(text, my_name: "Sam")
    assert_equal "Review: done", TemplateRenderer.render("Review: done\n\n{{google_review_link}}", {})
  end

  test "a set optional placeholder renders like any other" do
    text = "Please leave a review.\n\n{{google_review_link}}\n\nThanks"
    assert_equal "Please leave a review.\n\nhttps://g.page/r/x/review\n\nThanks",
      TemplateRenderer.render(text, google_review_link: "https://g.page/r/x/review")
  end

  test "placeholders_in lists unique names in order" do
    assert_equal %w[first_name trip first_name].uniq,
      TemplateRenderer.placeholders_in("Hi {{first_name}}, see {{trip}} ({{first_name}})")
  end

  test "placeholders_in ignores malformed braces" do
    assert_empty TemplateRenderer.placeholders_in("Hello {{ left alone }}")
  end
end
