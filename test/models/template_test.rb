require "test_helper"

class TemplateTest < ActiveSupport::TestCase
  test "requires a name and body, and email-only channel" do
    template = Template.new(purpose: "custom")
    assert_not template.valid?
    assert_includes template.errors[:name], "can't be blank"
    assert_includes template.errors[:body], "can't be blank"

    template.channel = "sms"
    assert_not template.valid?
    assert_includes template.errors[:channel], "is not included in the list"
  end

  test "purpose labels stay sentence case" do
    assert_equal "First reply", Template.new(purpose: "first_reply").purpose_label
    assert_equal "During-trip check-in", Template.new(purpose: "during_trip_checkin").purpose_label
  end

  test "ordered scope follows position" do
    second = Template.create!(name: "B", body: "b", purpose: "custom")
    first = Template.create!(name: "A", body: "a", purpose: "custom")
    first.update!(position: second.position - 1)
    assert_equal [ first, second ], Template.ordered.to_a.first(2)
  end

  test "active and archived scopes split on archived_at" do
    template = Template.create!(name: "Keep", body: "b", purpose: "custom")
    assert_includes Template.active, template
    template.archive!
    assert template.archived?
    assert_includes Template.archived, template
    assert_not_includes Template.active, template
    template.unarchive!
    assert_not template.archived?
    assert_includes Template.active, template
  end

  test "record_use counts the use and stamps last_used_at" do
    template = Template.create!(name: "Used", body: "b", purpose: "custom")
    assert_nil template.last_used_at
    template.record_use!
    assert_equal 1, template.reload.usage_count
    assert_in_delta Time.current, template.last_used_at, 5
    template.record_use!
    assert_equal 2, template.reload.usage_count
  end

  test "placeholders lists what subject and body need" do
    template = Template.new(subject: "Hi {{first_name}}", body: "About {{trip}}, {{first_name}}")
    assert_equal %w[first_name trip], template.placeholders
  end

  test "rendered fills from sample context with caller overrides" do
    template = Template.new(subject: "Hi {{first_name}}", body: "{{trip}} owes {{balance_due}}")
    rendered = template.rendered("first_name" => "Tashi")
    assert_equal "Hi Tashi", rendered[:subject]
    assert_includes rendered[:body], "Everest Base Camp trek"
  end

  test "move swaps positions within the purpose group" do
    one = Template.create!(name: "One", body: "b", purpose: "first_reply")
    two = Template.create!(name: "Two", body: "b", purpose: "first_reply")
    other = Template.create!(name: "Other", body: "b", purpose: "custom")
    assert_not one.move("up")
    assert_not two.move("down")
    assert two.move("up")
    assert_equal [ two.id, one.id ], Template.active.for_purpose("first_reply").ordered.map(&:id)
    assert_not two.move("up")
    assert_not one.move("down")
    assert one.move("up")
    assert_equal [ one.id, two.id ], Template.active.for_purpose("first_reply").ordered.map(&:id)
    assert_equal other.position, other.reload.position
  end
end
