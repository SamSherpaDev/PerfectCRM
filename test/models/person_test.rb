require "test_helper"

class PersonTest < ActiveSupport::TestCase
  test "normalizes email and keeps it unique per owner" do
    client = Client.create!(name: "Host")
    person = client.people.create!(name: "Maya", email: " MAYA@Example.com ")
    assert_equal "maya@example.com", person.reload.email
    dup_same_owner = client.people.new(name: "Clone", email: "maya@example.com")
    assert_not dup_same_owner.valid?
  end

  test "same email may live on different owners for lead conversion copies" do
    client = Client.create!(name: "Host")
    client.people.create!(name: "Maya", email: "maya@example.com")
    other_client = Client.create!(name: "Other")
    assert other_client.people.new(name: "Maya", email: "maya@example.com").valid?
    lead = Lead.create!(name: "Lead", source: "manual")
    assert lead.people.new(name: "Maya", email: "maya@example.com").valid?
  end

  test "phone is encrypted at rest" do
    client = Client.create!(name: "Host")
    person = client.people.create!(name: "Maya", phone: "+1-415-555-0199")
    raw = Person.connection.select_value(
      Person.sanitize_sql([ "SELECT phone FROM people WHERE id = ?", person.id ])
    )
    assert_not_includes raw.to_s, "555-0199"
    assert_equal "+1-415-555-0199", person.reload.phone
  end
end
