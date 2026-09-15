require "test_helper"

class MergeBatchTest < ActiveSupport::TestCase
  setup do
    @template = Template.new(name: "Check-in", subject: "Hi {{first_name}}",
      body: "{{full_name}}, enjoy {{trip}}!", purpose: "during_trip_checkin")
  end

  test "parses name/email pairs and bare emails, skipping blanks and junk" do
    recipients = MergeBatch.parse_recipients("Maya Gurung <maya@example.com>\n\npemba@example.com\nnot-an-email\n")
    assert_equal [ "Maya Gurung", "pemba@example.com" ], recipients.map(&:name)
    assert_equal [ "maya@example.com", "pemba@example.com" ], recipients.map(&:email)
  end

  test "build renders one personal message per recipient" do
    batch = MergeBatch.build(template: @template,
      recipient_lines: "Maya Gurung <maya@example.com>\nPemba Sherpa <pemba@example.com>")
    assert_equal 2, batch.size
    first, second = batch.messages
    assert_equal "maya@example.com", first.email
    assert_equal "Hi Maya", first.subject
    assert_includes first.body, "Maya Gurung"
    assert_equal "Hi Pemba", second.subject
    assert_includes second.body, "Pemba Sherpa"
  end

  test "empty recipient list builds an empty batch" do
    batch = MergeBatch.build(template: @template, recipient_lines: "   \n")
    assert_equal 0, batch.size
    assert_empty batch.messages
  end

  test "extra per-recipient context flows through without changing the renderer" do
    batch = MergeBatch.build(template: @template, recipient_lines: "Maya <maya@example.com>",
      context_for: ->(_recipient) { { "trip" => "Annapurna Circuit" } })
    assert_includes batch.messages.first.body, "Annapurna Circuit"
  end
end
