require "test_helper"

class SearchTest < ActiveSupport::TestCase
  test "client search matches name, email substring, tags, notes, and people" do
    tashi = Client.create!(name: "Tashi Sherpa", email: "tashi@example.com", tag_list: "everest")
    maya = Client.create!(name: "Maya Gurung", email: "maya@example.org")
    maya.people.create!(name: "Pasang", email: "pasang@example.net")
    Note.create!(notable: tashi, body: "Wants Annapurna in spring")

    assert_includes Client.search("tashi"), tashi
    assert_not_includes Client.search("tashi"), maya

    # Email substring across the domain.
    assert_includes Client.search("example.com"), tashi
    assert_not_includes Client.search("example.com"), maya

    # Person email finds the parent client.
    assert_includes Client.search("pasang@example"), maya

    # Tag text is indexed.
    assert_includes Client.search("everest"), tashi

    # Note text is indexed.
    assert_includes Client.search("annapurna"), tashi

    # Phone tail is indexed.
    tailed = Client.create!(name: "Tail", phone: "+1-415-555-0134")
    assert_includes Client.search("5550134"), tailed
  end

  test "client search stays in sync on edit" do
    client = Client.create!(name: "Old Name")
    assert_includes Client.search("old"), client
    client.update!(name: "New Name")
    assert_not_includes Client.search("old"), client
    assert_includes Client.search("new"), client
  end

  test "organization search matches name and email" do
    ops = Organization.create!(name: "Himalayan Ground", kind: "operator", email: "ops@example.com")
    advisor = Organization.create!(name: "Denver Travel", kind: "advisor")
    assert_includes Organization.search("himalayan"), ops
    assert_includes Organization.search("ops@example"), ops
    assert_not_includes Organization.search("himalayan"), advisor
  end

  test "blank query returns everything ordered" do
    first = Client.create!(name: "First")
    assert_includes Client.search(""), first
    assert_includes Client.search(nil), first
  end
end
