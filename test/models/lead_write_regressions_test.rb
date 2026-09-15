require "test_helper"

class LeadWriteRegressionsTest < ActiveSupport::TestCase
  test "a note loaded before conversion cannot save afterward" do
    lead = Lead.create!(name: "Traveler")
    note = Note.new(notable: Lead.find(lead.id), body: "Late note")
    client = lead.convert_to_client!
    assert_no_difference -> { Note.count + ActivityEvent.count } do
      assert_not note.save
    end
    assert_includes note.errors[:base], "Converted leads stay read-only"
    assert_equal 0, lead.reload.notes_count
    assert_empty client.notes
  end

  test "stale lead edits cannot save after conversion" do
    lead = Lead.create!(name: "Traveler")
    stale = Lead.find(lead.id)
    lead.convert_to_client!
    assert_not stale.update(name: "Late edit")
    assert_includes stale.errors[:base], "Converted leads stay read-only"
    assert_equal "Traveler", lead.reload.name
  end

  test "stale nested edits cannot save after conversion" do
    lead = Lead.create!(name: "Traveler")
    person = lead.people.create!(name: "Original")
    stale = Lead.includes(:people).find(lead.id)
    lead.convert_to_client!
    assert_not stale.update(people_attributes: [ { id: person.id, name: "Late edit" } ])
    assert_equal "Original", person.reload.name
  end

  test "writes completed before conversion move to the client" do
    lead = Lead.create!(name: "Traveler")
    lead.update!(name: "Updated")
    Note.create!(notable: lead, body: "Before conversion")
    client = lead.convert_to_client!
    assert_equal "Updated", client.name
    assert_equal [ "Before conversion" ], client.notes.pluck(:body)
    assert_equal 1, client.activity_events.where(kind: "note").count
  end
end
