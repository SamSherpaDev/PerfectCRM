require "test_helper"

class LeadIdentityTest < ActiveSupport::TestCase
  test "only open inquiries reserve identities including when reopening" do
    [ { email: "same@example.com" }, { perfectbook_contact_id: 123 } ].each do |identity|
      lost = Lead.create!(name: "Lost", status: "lost", lost_reason: "no_reply", **identity)
      active = Lead.create!(name: "Active", **identity)
      duplicate = Lead.new(name: "Duplicate", **identity)
      assert_not duplicate.save
      assert_not lost.update(status: "chatting")
      assert_equal "lost", lost.reload.status
      active.update!(status: "lost", lost_reason: "price")
      assert lost.update(status: "chatting")
    end
  end

  test "database enforces open identity uniqueness even without validation" do
    [ { email: "same@example.com" }, { perfectbook_contact_id: 123 } ].each do |identity|
      Lead.create!(name: "Active", **identity)
      duplicate = Lead.new(name: "Duplicate", **identity)
      assert_raises(ActiveRecord::RecordNotUnique) do
        Lead.transaction(requires_new: true) { duplicate.save!(validate: false) }
      end
      assert Lead.new(name: "Lost", status: "lost", **identity).save(validate: false)
    end
  end

  test "external references remain unique across historical inquiries" do
    lead = Lead.create!(name: "Lost", status: "lost", lost_reason: "other", external_ref: "import-1")
    duplicate = Lead.new(name: "Another inquiry", external_ref: lead.external_ref)
    assert_not duplicate.save
    assert_raises(ActiveRecord::RecordNotUnique) do
      Lead.transaction(requires_new: true) { duplicate.save!(validate: false) }
    end
  end
end
