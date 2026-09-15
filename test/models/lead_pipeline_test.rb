require "test_helper"

class LeadPipelineTest < ActiveSupport::TestCase
  test "lost requires a reason" do
    lead = Lead.new(name: "Quiet", source: "manual", status: "lost")
    assert_not lead.valid?
    assert_includes lead.errors[:lost_reason], "is required when a lead is lost"

    lead.lost_reason = "price"
    assert lead.valid?
  end

  test "lost reason must be known" do
    lead = Lead.new(name: "Quiet", source: "manual", status: "lost", lost_reason: "aliens")
    assert_not lead.valid?
    assert lead.errors[:lost_reason].any?
  end

  test "non-lost leads need no reason" do
    assert Lead.new(name: "Chatty", source: "manual", status: "chatting").valid?
  end

  test "expected value must be a non-negative integer or blank" do
    assert Lead.new(name: "A", source: "manual", expected_value_minor: 250_000).valid?
    assert Lead.new(name: "B", source: "manual").valid?
    assert_not Lead.new(name: "C", source: "manual", expected_value_minor: -1).valid?
  end

  test "expected value dollars round-trips" do
    lead = Lead.new(name: "Dollars", source: "manual")
    lead.expected_value_dollars = "2,500.50"
    assert_equal 250_050, lead.expected_value_minor
    assert_equal 2500.5, lead.expected_value_dollars
    lead.expected_value_dollars = ""
    assert_nil lead.expected_value_minor
  end

  test "new leads stamp stage and touch" do
    lead = Lead.create!(name: "Fresh", source: "manual")
    assert lead.stage_changed_at.present?
    assert lead.last_touch_at.present?
  end

  test "stale after seven quiet days, never when lost or converted" do
    quiet = Lead.create!(name: "Quiet", source: "manual")
    quiet.update_columns(last_touch_at: 8.days.ago, last_activity_at: 8.days.ago, updated_at: 8.days.ago)
    assert quiet.reload.stale?

    fresh = Lead.create!(name: "Fresh", source: "manual")
    assert_not fresh.stale?

    lost = Lead.create!(name: "Lost", source: "manual", status: "lost", lost_reason: "no_reply")
    lost.update_columns(last_touch_at: 30.days.ago, last_activity_at: 30.days.ago, updated_at: 30.days.ago)
    assert_not lost.reload.stale?
  end

  test "stale scope matches stale predicate" do
    quiet = Lead.create!(name: "Quiet scope", source: "manual")
    quiet.update_columns(last_touch_at: 8.days.ago, last_activity_at: 8.days.ago, updated_at: 8.days.ago)
    assert_includes Lead.stale.map(&:id), quiet.id
  end

  test "stage age counts whole days" do
    lead = Lead.create!(name: "Aged", source: "manual")
    lead.update_column(:stage_changed_at, 3.days.ago)
    assert_equal 3, lead.reload.stage_age_days
  end

  test "notes maintain last touch" do
    lead = Lead.create!(name: "Noted", source: "manual")
    lead.update_columns(last_touch_at: 8.days.ago, last_activity_at: 8.days.ago)
    assert lead.reload.stale?
    lead.notes.create!(body: "Called back")
    assert_not lead.reload.stale?
  end

  test "trip interest strips blanks" do
    lead = Lead.create!(name: "Trip", source: "manual", trip_interest: "  ")
    assert_nil lead.reload.trip_interest
  end
end
