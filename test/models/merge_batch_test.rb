require "test_helper"

class MergeBatchTest < ActiveSupport::TestCase
  setup do
    @template = Template.new(name: "Check-in", subject: "Hi {{first_name}}",
      body: "{{full_name}}, enjoy {{trip}}!", purpose: "during_trip_checkin")
  end

  test "parses name/email pairs and bare emails, skipping blanks" do
    recipients = MergeBatch.parse_recipients("Maya Gurung <maya@example.com>\n\npemba@example.com\n")
    assert_equal [ "Maya Gurung", "pemba@example.com" ], recipients.map(&:name)
    assert_equal [ "maya@example.com", "pemba@example.com" ], recipients.map(&:email)
  end

  # Correction B: malformed lines are retained with line numbers as
  # errors, never silently dropped. The batch is not complete until they
  # are fixed or removed.
  test "malformed lines come back as numbered errors and block completion" do
    batch = MergeBatch.build(template: @template,
      recipient_lines: "Maya Gurung <maya@example.com>\nnot-an-email\n\nBroken <nope>\n")
    assert_equal 1, batch.size
    assert_equal [ "maya@example.com" ], batch.recipients.map(&:email)
    assert_equal [ 2, 4 ], batch.errors.map(&:line_number)
    assert_equal [ "not-an-email", "Broken <nope>" ], batch.errors.map(&:line)
    assert_not batch.complete?
  end

  test "a clean batch with recipients is complete" do
    batch = MergeBatch.build(template: @template,
      recipient_lines: "Maya <maya@example.com>")
    assert batch.complete?
  end

  test "an empty batch is not complete" do
    batch = MergeBatch.build(template: @template, recipient_lines: "   \n")
    assert_equal 0, batch.size
    assert_empty batch.messages
    assert_not batch.complete?
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
    assert_not batch.complete?
  end

  test "extra per-recipient context flows through without changing the renderer" do
    batch = MergeBatch.build(template: @template, recipient_lines: "Maya <maya@example.com>",
      context_for: ->(_recipient) { { "trip" => "Annapurna Circuit" } })
    assert_includes batch.messages.first.body, "Annapurna Circuit"
  end
end
