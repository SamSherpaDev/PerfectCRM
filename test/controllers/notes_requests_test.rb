require "test_helper"
require_relative "../support/google_sign_in_test_helper"

class NotesRequestsTest < ActionDispatch::IntegrationTest
  include GoogleSignInTestHelper

  setup do
    sign_in
  end

  test "create a note on a client" do
    client = Client.create!(name: "Tashi")
    assert_difference -> { client.notes.count }, 1 do
      post client_notes_path(client), params: { note: { body: "Called about May" } }
    end
    assert_redirected_to client_path(client)
    assert_equal 1, client.reload.notes_count
  end

  test "create a note on an organization" do
    org = Organization.create!(name: "Ops")
    assert_difference -> { org.notes.count }, 1 do
      post organization_notes_path(org), params: { note: { body: "Met at expo" } }
    end
    assert_redirected_to organization_path(org)
  end

  test "destroy a note" do
    client = Client.create!(name: "Tashi")
    note = Note.create!(notable: client, body: "Temp")
    assert_difference -> { Note.count }, -1 do
      delete note_path(note)
    end
    assert_redirected_to client_path(client)
  end
end
