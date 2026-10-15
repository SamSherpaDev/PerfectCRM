require "test_helper"

class LeadPotentialTest < ActiveSupport::TestCase
  test "Potential is reversible across stages and independent of fit" do
    lead = Lead.create!(name: "Follow up", status: "quoted", owner_fit_at_inquiry: "possible", fit_score: 80, fit_band: "strong")
    lead.mark_potential!
    marked_at = lead.reload.potential_marked_at
    lead.mark_potential!
    assert_equal marked_at, lead.reload.potential_marked_at
    assert lead.potential?
    assert_includes Lead.potential, lead
    assert_equal [ "quoted", "possible", 80, "strong" ], lead.attributes.values_at("status", "owner_fit_at_inquiry", "fit_score", "fit_band")
    lead.unmark_potential!
    assert_not lead.reload.potential?
    assert_not_includes Lead.potential, lead
  end

  test "spam clears Potential and restoring does not reapply it" do
    lead = Lead.create!(name: "Follow up")
    lead.mark_potential!
    lead.mark_as_spam!
    assert_nil lead.reload.potential_marked_at
    assert_not_includes Lead.potential, lead
    lead.mark_not_spam!
    assert_not lead.reload.potential?
    assert_not_includes Lead.potential, lead
  end

  test "archived converted and suspected spam leads cannot enter Potential" do
    archived = Lead.create!(name: "Archived")
    archived.mark_potential!
    archived.archive!
    converted = Lead.create!(name: "Converted")
    converted.mark_potential!
    converted.convert_to_client!
    flagged = Lead.create!(name: "Flagged", tag_list: Lead::SUSPECTED_SPAM_TAG, potential_marked_at: Time.current)
    [ archived, converted, flagged ].each do |lead|
      assert_not lead.potential?
      assert_not_includes Lead.potential, lead
      assert_raises(ActiveRecord::RecordInvalid) { lead.mark_potential! }
    end
    [ archived, converted ].each do |lead|
      assert_raises(ActiveRecord::RecordInvalid) { lead.unmark_potential! }
    end
  end
end
