require "test_helper"

class ClientTest < ActiveSupport::TestCase
  test "normalizes email to lowercase and strips" do
    client = Client.create!(name: "Tashi", email: "  TASHI@Example.COM ")
    assert_equal "tashi@example.com", client.reload.email
  end

  test "blank email becomes nil and allows multiples" do
    first = Client.create!(name: "One", email: "")
    second = Client.create!(name: "Two")
    assert_nil first.reload.email
    assert_nil second.reload.email
  end

  test "email is unique case-insensitively" do
    Client.create!(name: "One", email: "a@example.com")
    other = Client.new(name: "Two", email: "A@EXAMPLE.COM")
    assert_not other.valid?
    assert_includes other.errors[:email], "has already been taken"
  end

  test "kind and source enumerations" do
    client = Client.new(name: "X", kind: "alien")
    assert_not client.valid?
    client.kind = "company"
    client.source = "smoke-signal"
    assert_not client.valid?
    client.source = "referral"
    assert client.valid?
  end

  test "perfectbook contact id is unique when present" do
    Client.create!(name: "One", perfectbook_contact_id: 42)
    other = Client.new(name: "Two", perfectbook_contact_id: 42)
    assert_not other.valid?
  end

  test "phone is encrypted at rest" do
    client = Client.create!(name: "Tashi", phone: "+1-415-555-0134")
    raw = Client.connection.select_value(
      Client.sanitize_sql([ "SELECT phone FROM clients WHERE id = ?", client.id ])
    )
    assert_not_includes raw.to_s, "415-555"
    assert_equal "+1-415-555-0134", client.reload.phone
  end

  test "archiving scopes" do
    client = Client.create!(name: "Archie")
    assert_includes Client.active, client
    client.archive!
    assert client.reload.archived?
    assert_includes Client.archived, client
    assert_not_includes Client.active, client
    client.unarchive!
    assert_not client.reload.archived?
  end

  test "tag list assigns tags" do
    client = Client.create!(name: "Tagged", tag_list: "Everest-Interested, honeymoon,  ")
    assert_equal %w[everest-interested honeymoon], client.reload.tags.order(:name).pluck(:name)
  end

  test "nested people are created inline" do
    client = Client.create!(
      name: "Family",
      people_attributes: [ { name: "Maya", role: "spouse", email: "maya@example.com" } ]
    )
    assert_equal "Maya", client.reload.people.first.name
  end
end
