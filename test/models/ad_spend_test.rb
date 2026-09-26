require "test_helper"

class AdSpendTest < ActiveSupport::TestCase
  test "record snaps to the Monday and replaces the same week, channel, and campaign" do
    entry = AdSpend.record!(week_start: Date.new(2026, 9, 17), source: "google_ads", campaign_name: " EBC ", amount_dollars: "$1,126.50")
    assert_equal Date.new(2026, 9, 14), entry.week_start
    assert_equal "EBC", entry.campaign_name
    assert_equal 112_650, entry.amount_minor

    AdSpend.record!(week_start: Date.new(2026, 9, 20), source: "google_ads", campaign_name: "EBC", amount_dollars: "90")
    assert_equal [ 9_000 ], AdSpend.pluck(:amount_minor)
  end

  test "rejects unknown channels and amounts that are not money" do
    assert_raises(ActiveRecord::RecordInvalid) do
      AdSpend.record!(week_start: Date.new(2026, 9, 14), source: "tiktok", campaign_name: "", amount_dollars: "10")
    end
    error = assert_raises(ActiveRecord::RecordInvalid) do
      AdSpend.record!(week_start: Date.new(2026, 9, 14), source: "meta_ads", campaign_name: "", amount_dollars: "ten")
    end
    assert_includes error.record.errors.full_messages, "Enter the amount spent, like 126 or 126.50"
  end
  test "requires a campaign name" do
    error = assert_raises(ActiveRecord::RecordInvalid) do
      AdSpend.record!(week_start: Date.new(2026, 9, 14), source: "meta_ads", campaign_name: " ", amount_dollars: "100")
    end
    assert_includes error.record.errors.full_messages, "Campaign name can't be blank"
  end

end
