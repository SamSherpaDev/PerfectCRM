require "test_helper"
require_relative "../support/google_sign_in_test_helper"

class OrganizationsRequestsTest < ActionDispatch::IntegrationTest
  include GoogleSignInTestHelper

  setup do
    sign_in
  end

  test "show renders facts, referrals, notes, and timeline" do
    org = Organization.create!(name: "Himalayan Ground", kind: "operator", email: "ops@example.com", perfectbook_contact_id: 55)
    client = Client.create!(name: "Tashi", referred_by_organization: org)
    Note.create!(notable: org, body: "Reliable")
    get organization_path(org)
    assert_response :success
    assert_select "h1", "Himalayan Ground"
    assert_select "a", text: "Open in PerfectBook"
    assert_select "a", text: "Tashi"
    assert_select "h2", text: "Notes"
    assert_select "h2", text: "Timeline"
  end

  test "new and create" do
    get new_organization_path
    assert_response :success
    post organizations_path, params: {
      organization: { name: "Denver Travel", kind: "advisor", email: "hi@denver.example", tag_list: "advisor" }
    }
    assert_redirected_to organization_path(Organization.last)
    assert_equal "advisor", Organization.last.kind
  end

  test "edit and update" do
    org = Organization.create!(name: "Ops")
    get edit_organization_path(org)
    assert_response :success
    patch organization_path(org), params: { organization: { name: "Ops Updated" } }
    assert_redirected_to organization_path(org)
    assert_equal "Ops Updated", org.reload.name
  end
end
