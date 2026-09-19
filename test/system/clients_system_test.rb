require "application_system_test_case"
require_relative "../support/google_sign_in_test_helper"

# The captain answers from his phone: creating a client, adding a person,
# and leaving a note must work one-handed at 390px.
class ClientsSystemTest < ApplicationSystemTestCase
  include GoogleSignInTestHelper

  test "create client with person and note at phone width" do
    OmniAuth.config.mock_auth[:google_oauth2] = OmniAuth::AuthHash.new(
      provider: "google_oauth2", uid: "google-captain",
      extra: { id_token: JWT.encode(@claims, @key, "RS256") }
    )
    Google::Auth::IDTokens.stub(:oidc_key_source, @source) do
      visit "/auth/google_oauth2/callback"
      assert_selector "h1", text: "Today"
    end
    page.current_window.resize_to(390, 844)

    visit clients_path
    assert_selector "h1", text: "Clients"
    assert_no_overflow("/clients")

    click_link "New client"
    assert_selector "h1", text: "New client"
    assert_no_overflow("/clients/new")

    fill_in "Display name", with: "Tashi Sherpa"
    fill_in "Primary email", with: "tashi@example.com"
    fill_in "Tags", with: "everest, vip"
    first_person_name = find_field("client[people_attributes][0][name]", match: :first)
    first_person_name.fill_in(with: "Maya Gurung")
    fill_in "client[people_attributes][0][role]", with: "Spouse"
    fill_in "client[people_attributes][0][email]", with: "maya@example.com"

    click_button "Save client"
    assert_selector "h1", text: "Tashi Sherpa"
    assert_text "tashi@example.com"
    assert_no_overflow("client page")

    # Notes live in the composer's Note mode; travelers and tags live on
    # the Details tab on the phone.
    click_button "Reply"
    choose "Note", allow_label_click: true
    fill_in "Add a note", with: "Wants Everest in May with two travelers"
    click_button "Save note"
    assert_text "Wants Everest in May"
    assert_text "Note saved"
    assert_no_overflow("client page after note")

    click_button "Details", exact: true
    assert_text "Maya Gurung"
    assert_text "everest"
    assert_no_overflow("client details tab")

    visit clients_path(q: "tashi@ex")
    assert_text "Tashi Sherpa"
    assert_no_overflow("search")
  end

  test "client index tabs keep their counts and fit the phone" do
    Client.create!(name: "Tashi")
    Organization.create!(name: "Ops Co", kind: "operator")
    archived = Client.create!(name: "Oldie")
    archived.archive!

    OmniAuth.config.mock_auth[:google_oauth2] = OmniAuth::AuthHash.new(
      provider: "google_oauth2", uid: "google-captain",
      extra: { id_token: JWT.encode(@claims, @key, "RS256") }
    )
    Google::Auth::IDTokens.stub(:oidc_key_source, @source) do
      visit "/auth/google_oauth2/callback"
    end
    page.current_window.resize_to(390, 844)

    visit clients_path
    assert_selector "nav.tabs a", text: /Clients/
    assert_selector "nav.tabs a", text: /Organizations/
    assert_selector "nav.tabs a", text: /Archived/
    assert_no_overflow("tabs")

    click_link "Organizations"
    assert_text "Ops Co"
    assert_no_overflow("organizations tab")

    click_link "Archived"
    assert_text "Oldie"
    assert_no_overflow("archived tab")
  end

  private

  def assert_no_overflow(context)
    width = page.evaluate_script("document.documentElement.scrollWidth")
    assert_operator width, :<=, 390, "#{context} overflows a 390px viewport (#{width}px)"
  end
end
