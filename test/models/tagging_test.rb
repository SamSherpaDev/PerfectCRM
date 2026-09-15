require "test_helper"

class TaggingTest < ActiveSupport::TestCase
  test "tag names are normalized and unique" do
    tag = Tag.create!(name: " Everest-Interested ")
    assert_equal "everest-interested", tag.reload.name
    assert_not Tag.new(name: "EVEREST-INTERESTED").valid?
  end

  test "tagging is unique per taggable" do
    client = Client.create!(name: "Tashi")
    tag = Tag.create!(name: "vip")
    client.tags << tag
    dup = Tagging.new(tag: tag, taggable: client)
    assert_not dup.valid?
  end

  test "tags work on organizations too" do
    org = Organization.create!(name: "Ops")
    tag = Tag.create!(name: "operator")
    org.tags << tag
    assert_includes org.reload.tags, tag
  end
end
