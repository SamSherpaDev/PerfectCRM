require "test_helper"

class LeadSpamTest < ActiveSupport::TestCase
  test "owner spam verdict archives without losing inquiry data and not spam restores it" do
    lead = Lead.create!(name: "Demo inquiry", email: "demo@example.test", message: "Original inquiry",
      spam_score: 25, tag_list: "trekking", fit_band: "possible")
    note = lead.notes.create!(body: "Keep this history")
    Current.user_email = "captain@example.test"

    lead.mark_as_spam!
    assert lead.reload.archived?
    assert lead.spam_marked_at.present?
    assert lead.suspected_spam?
    assert_equal %w[suspected_spam trekking], lead.tags.pluck(:name)
    assert_equal "spam", lead.activity_events.last.metadata["verdict"]
    assert_equal "captain@example.test", lead.activity_events.last.metadata["actor"]

    # A later tag edit cannot silently erase the owner's recorded verdict.
    lead.update!(tag_list: "trekking")
    assert lead.reload.suspected_spam?
    assert_includes Lead.spam, lead

    lead.mark_not_spam!
    assert_not lead.reload.archived?
    assert_nil lead.spam_marked_at
    assert_not lead.suspected_spam?
    assert_not_includes Lead.spam, lead
    assert_equal "not_spam", lead.activity_events.last.metadata["verdict"]
    assert_equal [ "Original inquiry", 25, "possible", "new" ],
      [ lead.message, lead.spam_score, lead.fit_band, lead.status ]
    assert_equal [ note ], lead.notes.to_a
    assert_equal [ "trekking" ], lead.tags.pluck(:name)
  ensure
    Current.reset
  end

  test "not spam clears an automatic flag without changing its score" do
    lead = Lead.create!(name: "Auto flagged", spam_score: 70, tag_list: "suspected_spam, trekking")
    lead.mark_not_spam!
    assert_not lead.reload.suspected_spam?
    assert_equal 70, lead.spam_score
    assert_nil lead.spam_marked_at
    assert_equal [ "trekking" ], lead.tags.pluck(:name)
  end

  test "ordinary restore also clears a confirmed spam verdict" do
    lead = Lead.create!(name: "Mistaken spam")
    stale = Lead.find(lead.id)
    lead.mark_as_spam!
    stale.unarchive!
    assert_not lead.reload.archived?
    assert_not lead.suspected_spam?
  end

  test "failed restoration keeps the archive verdict and spam tag together" do
    lead = Lead.create!(name: "Spam with contact", perfectbook_contact_id: 987654)
    lead.mark_as_spam!
    Lead.create!(name: "Current inquiry", perfectbook_contact_id: lead.perfectbook_contact_id)

    assert_raises(ActiveRecord::RecordInvalid) { lead.mark_not_spam! }
    assert lead.reload.archived?
    assert lead.spam_marked_at.present?
    assert lead.tags.exists?(name: Lead::SUSPECTED_SPAM_TAG)
    assert_empty lead.activity_events.where(kind: "spam_review").where("json_extract(metadata, '$.verdict') = ?", "not_spam")
  end

  test "converted leads cannot be reviewed as spam or not spam" do
    lead = Lead.create!(name: "Booked traveler")
    lead.convert_to_client!
    [ :mark_as_spam!, :mark_not_spam! ].each do |action|
      assert_raises(ActiveRecord::RecordInvalid) { lead.public_send(action) }
      assert_nil lead.reload.spam_marked_at
      assert_not lead.archived?
      assert_empty lead.tags
    end
  end

  test "a failed archive rolls back its spam tag and verdict" do
    lead = Lead.create!(name: "Archive failure")
    lead.stub(:archive!, -> { raise ActiveRecord::RecordInvalid, lead }) do
      assert_raises(ActiveRecord::RecordInvalid) { lead.mark_as_spam! }
    end
    assert_nil lead.reload.spam_marked_at
    assert_not lead.archived?
    assert_empty lead.tags
    assert_empty lead.activity_events.where(kind: "spam_review")
  end
end
