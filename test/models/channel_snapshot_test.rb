require "test_helper"

class ChannelSnapshotTest < ActiveSupport::TestCase
  test "inquiries are optional nonnegative counts owned only by organic checks" do
    ChannelSnapshot::CHANNELS.each_key do |channel|
      snapshot = ChannelSnapshot.new(channel: channel, checked_at: Time.current)
      assert snapshot.valid?
      snapshot.inquiries = 0
      assert_equal !AdSpend::SOURCES.include?(channel), snapshot.valid?
      [ -1, 1.5, ChannelSnapshot::MAX_COUNT + 1 ].each do |value|
        snapshot.inquiries = value
        assert_not snapshot.valid?
        assert snapshot.errors[:inquiries].any?
      end
    end
  end
end
