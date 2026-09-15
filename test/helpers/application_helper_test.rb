require "test_helper"

class ApplicationHelperTest < ActionView::TestCase
  test "stage badges carry every pipeline stage with its tone" do
    tones = {
      "new" => "badge-info", "chatting" => "badge-neutral", "quoted" => "badge-brand",
      "nudged" => "badge-warning", "won" => "badge-success",
      "post_trip" => "badge-info", "lost" => "badge-quiet"
    }
    tones.each do |stage, css|
      html = stage_badge(stage)
      assert_includes html, css, "expected #{stage} to use #{css}"
      assert_includes html, stage.humanize
    end
  end

  test "orb renders a labelled canvas wired to the stimulus controller" do
    html = orb(:shaping, size: 64)
    assert_includes html, 'data-controller="orb"'
    assert_includes html, 'data-orb-state-value="shaping"'
    assert_includes html, 'data-orb-size-value="64"'
    assert_includes html, 'aria-label="Shaping…"'
    html = orb(:bogus, size: 13)
    assert_includes html, 'data-orb-state-value="composing"'
    assert_includes html, 'data-orb-size-value="20"'
  end

  test "sketch resolves crm drawings with their aspect handling" do
    assert_includes sketch(:everest), "#sk-everest"
    assert_includes sketch(:"mark-a"), "#sk-mark-a"
    assert_includes sketch(:stream), 'preserveAspectRatio="none"'
    assert_includes sketch(:everest), 'preserveAspectRatio="xMaxYMax meet"'
  end
end
