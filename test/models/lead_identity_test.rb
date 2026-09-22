require "test_helper"

class LeadIdentityTest < ActiveSupport::TestCase
  test "open inquiries share an email address while PerfectBook links stay unique" do
    Lead.create!(name: "First inquiry", email: "repeat@example.com")
    second = Lead.new(name: "Second inquiry", email: "repeat@example.com")
    assert second.save
    assert_equal "repeat@example.com", second.reload.email
  end

  test "only open inquiries reserve the PerfectBook link including when reopening" do
    lost = Lead.create!(name: "Lost", status: "lost", lost_reason: "no_reply", perfectbook_contact_id: 123)
    active = Lead.create!(name: "Active", perfectbook_contact_id: 123)
    assert_not Lead.new(name: "Duplicate", perfectbook_contact_id: 123).save
    assert_not lost.update(status: "chatting")
    assert_equal "lost", lost.reload.status
    active.update!(status: "lost", lost_reason: "price")
    assert lost.update(status: "chatting")
  end

  test "database enforces open PerfectBook link uniqueness even without validation" do
    Lead.create!(name: "Active", perfectbook_contact_id: 123)
    duplicate = Lead.new(name: "Duplicate", perfectbook_contact_id: 123)
    assert_raises(ActiveRecord::RecordNotUnique) do
      Lead.transaction(requires_new: true) { duplicate.save!(validate: false) }
    end
    assert Lead.new(name: "Lost", status: "lost", lost_reason: "no_reply", perfectbook_contact_id: 123).save(validate: false)
  end

  test "database allows duplicate open emails" do
    Lead.create!(name: "Active", email: "repeat@example.com")
    duplicate = Lead.new(name: "Second inquiry", email: "repeat@example.com")
    Lead.transaction(requires_new: true) { duplicate.save!(validate: false) }
    assert duplicate.persisted?
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
