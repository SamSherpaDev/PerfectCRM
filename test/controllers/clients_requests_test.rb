require "test_helper"
require_relative "../support/google_sign_in_test_helper"

class ClientsRequestsTest < ActionDispatch::IntegrationTest
  include GoogleSignInTestHelper

  setup do
    sign_in
  end

  test "index renders tabs with counts and search" do
    Client.create!(name: "Tashi", source: "website")
    Organization.create!(name: "Ops Co", kind: "operator")
    archived = Client.create!(name: "Oldie")
    archived.archive!

    get clients_path
    assert_response :success
    assert_select "h1", "Clients"
    assert_select "nav.tabs a", text: /Clients/
    assert_select "nav.tabs a", text: /Organizations/
    assert_select "nav.tabs a", text: /Archived/
    assert_select "form input[name=q]"
    assert_select "a", text: "Tashi"
  end

  test "index organizations tab lists organizations" do
    Organization.create!(name: "Himalayan Ground", kind: "operator")
    get clients_path(tab: "organizations")
    assert_response :success
    assert_select "a", text: "Himalayan Ground"
  end

  test "index archived tab lists archived clients" do
    client = Client.create!(name: "Oldie")
    client.archive!
    get clients_path(tab: "archived")
    assert_response :success
    assert_select "a", text: "Oldie"
  end

  test "index search filters by email fragment" do
    Client.create!(name: "Tashi", email: "tashi@example.com")
    Client.create!(name: "Maya", email: "maya@other.org")
    get clients_path(q: "tashi@ex")
    assert_response :success
    assert_select "a", text: "Tashi"
    assert_select "a", { text: "Maya", count: 0 }
  end

  test "show renders facts, people, notes, timeline and future slots" do
    org = Organization.create!(name: "Referrer", kind: "advisor")
    client = Client.create!(
      name: "Tashi", email: "tashi@example.com", source: "referral",
      referred_by_organization: org, tag_list: "everest",
      perfectbook_contact_id: 123
    )
    client.people.create!(name: "Maya", role: "spouse")
    get client_path(client)
    assert_response :success
    assert_select "h1", "Tashi"
    assert_select "a", text: "Open in PerfectBook"
    assert_select "a[href=?]", "https://perfectbook.sherpaholidays.com/contacts/123"
    assert_select "h2", text: "Details"
    assert_select "h2", text: "Timeline"
    assert_select "h2", text: "Upcoming"
    assert_select "h2", text: "Files"
    assert_select "h2", text: "Trip in PerfectBook"
    assert_select "h2", { text: "People", count: 0 }
    assert_select "h2", { text: "Notes", count: 0 }
    assert_select "h2", { text: "Follow-ups", count: 0 }
    assert_select "h2", { text: "Bookings in PerfectBook", count: 0 }
    assert_select "li", text: /Maya/
    assert_select ".chip", text: "everest"
    assert_select "p", text: /Replies you send from here will appear on this timeline/, count: 0
  end

  test "show renders notes and timeline events newest first" do
    client = Client.create!(name: "Tashi")
    Note.create!(notable: client, body: "Loves spring")
    get client_path(client)
    assert_response :success
    assert_select ".timeline .ev.note", text: /Loves spring/
    assert_select "ol li", text: /Note added/, count: 0
  end

  test "new and create with inline person and tags" do
    get new_client_path
    assert_response :success
    post clients_path, params: {
      client: {
        name: "Tashi", email: "tashi@example.com", kind: "individual",
        source: "website", tag_list: "everest, vip",
        people_attributes: [ { name: "Maya", role: "spouse", email: "maya@example.com" } ]
      }
    }
    assert_redirected_to client_path(Client.last)
    follow_redirect!
    assert_select "h1", "Tashi"
    assert_equal "maya@example.com", Client.last.people.first.email
    assert_equal %w[everest vip], Client.last.tags.order(:name).pluck(:name)
  end

  test "edit and update" do
    client = Client.create!(name: "Tashi")
    get edit_client_path(client)
    assert_response :success
    patch client_path(client), params: { client: { name: "Tashi Updated" } }
    assert_redirected_to client_path(client)
    assert_equal "Tashi Updated", client.reload.name
  end

  test "archive and unarchive" do
    client = Client.create!(name: "Tashi")
    patch archive_client_path(client)
    assert_redirected_to clients_path(tab: "archived")
    assert client.reload.archived?
    patch unarchive_client_path(client)
    assert_redirected_to client_path(client)
    assert_not client.reload.archived?
  end

  test "by-perfectbook redirects to the linked client" do
    client = Client.create!(name: "Tashi", perfectbook_contact_id: 99)
    get by_perfectbook_clients_path(perfectbook_contact_id: 99)
    assert_redirected_to client_path(client)
  end

  test "by-perfectbook redirects to the linked organization" do
    org = Organization.create!(name: "Ops", perfectbook_contact_id: 77)
    get by_perfectbook_clients_path(perfectbook_contact_id: 77)
    assert_redirected_to organization_path(org)
  end

  test "by-perfectbook offers create when nothing is linked" do
    get by_perfectbook_clients_path(perfectbook_contact_id: 4242)
    assert_response :not_found
    assert_select "h1", text: /Link PerfectBook/
    # Hidden field carries the id through to create.
    assert_select "form input[type=hidden][name='client[perfectbook_contact_id]']"
  end

  test "by-perfectbook rejects a bad id" do
    get by_perfectbook_clients_path(perfectbook_contact_id: "abc")
    assert_response :not_found
  end

  test "signed-out clients pages redirect" do
    delete sign_out_path
    get clients_path
    assert_redirected_to sign_in_path
    client = Client.create!(name: "Tashi")
    get client_path(client)
    assert_redirected_to sign_in_path
  end
end
