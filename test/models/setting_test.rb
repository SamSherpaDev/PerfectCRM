require "test_helper"

class SettingTest < ActiveSupport::TestCase
  test "current is a paper singleton" do
    assert_equal "paper", Setting.current.appearance
    assert_equal Setting.current.id, Setting.current.id
  end

  test "appearance only accepts paper and night" do
    settings = Setting.current
    settings.update!(appearance: "night")
    assert_equal "night", settings.reload.appearance
    settings.appearance = "device"
    assert_not settings.valid?
    assert_includes settings.errors[:appearance], "is not included in the list"
  end

  test "only one settings row can exist" do
    Setting.current
    assert_not Setting.new(singleton_key: 1).valid?
    assert_not Setting.new(singleton_key: 2).valid?
  end
end
