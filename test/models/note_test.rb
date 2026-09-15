require "test_helper"

class NoteTest < ActiveSupport::TestCase
  test "note bumps the client counter and timeline" do
    client = Client.create!(name: "Tashi")
    assert_difference -> { client.reload.notes_count }, 1 do
      Note.create!(notable: client, body: "Loves Everest")
    end
    assert_equal 1, client.reload.activity_events.where(kind: "note").count
    assert_not_nil client.reload.last_activity_at
  end

  test "note works on organizations" do
    org = Organization.create!(name: "Ops")
    note = Note.create!(notable: org, body: "Reliable in Lukla")
    assert_equal org, note.reload.notable
    assert_equal 1, org.reload.activity_events.count
  end

  test "body is required" do
    client = Client.create!(name: "Tashi")
    assert_not Note.new(notable: client, body: " ").valid?
  end
end
