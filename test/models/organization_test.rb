require "test_helper"

class OrganizationTest < ActiveSupport::TestCase
  test "normalizes email and validates kind" do
    org = Organization.create!(name: "Ops Co", kind: "operator", email: " OPS@Example.com ")
    assert_equal "ops@example.com", org.reload.email
    bad = Organization.new(name: "X", kind: "alien")
    assert_not bad.valid?
  end

  test "perfectbook contact id is unique" do
    Organization.create!(name: "One", perfectbook_contact_id: 7)
    assert_not Organization.new(name: "Two", perfectbook_contact_id: 7).valid?
  end

  test "phone is encrypted at rest" do
    org = Organization.create!(name: "Ops", phone: "+977-1-4445555")
    raw = Organization.connection.select_value(
      Organization.sanitize_sql([ "SELECT phone FROM organizations WHERE id = ?", org.id ])
    )
    assert_not_includes raw.to_s, "4445555"
    assert_equal "+977-1-4445555", org.reload.phone
  end
end
