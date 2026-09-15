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

  test "destructive contact and note routes are unavailable" do
    %w[/notes/1 /organizations/1 /clients/1 /leads/1].each do |path|
      assert_raises(ActionController::RoutingError) do
        Rails.application.routes.recognize_path(path, method: :delete)
      end
    end
    assert_raises(ActionController::RoutingError) do
      Rails.application.routes.recognize_path("/organizations", method: :get)
    end
  end
end
