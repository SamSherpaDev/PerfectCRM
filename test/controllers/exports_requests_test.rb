require "test_helper"
require_relative "../support/google_sign_in_test_helper"

class ExportsRequestsTest < ActionDispatch::IntegrationTest
  include GoogleSignInTestHelper

  setup do
    sign_in
  end

  test "export streams a zip of five csv files with a bom" do
    org = Organization.create!(name: "Ops Co", kind: "operator", email: "ops@example.com")
    Lead.create!(name: "Ad Lead", source: "google_ads", campaign_name: "Everest", external_ref: "n8n-1")
    client = Client.create!(name: "Tashi", email: "tashi@example.com", referred_by_organization: org)
    client.people.create!(name: "Maya", email: "maya@example.com")
    Note.create!(notable: client, body: "Loves Everest")

    get settings_export_path
    assert_response :success
    assert_equal "application/zip", response.media_type

    files = {}
    Zip::InputStream.open(StringIO.new(response.body)) do |zip|
      while (entry = zip.get_next_entry)
        files[entry.name] = zip.read.force_encoding(Encoding::UTF_8)
      end
    end

    assert_equal %w[clients.csv leads.csv notes.csv organizations.csv people.csv], files.keys.sort
    files.each_value do |content|
      assert content.start_with?("\uFEFF"), "expected a UTF-8 BOM for Excel"
    end

    clients = CSV.parse(files["clients.csv"].delete_prefix("\uFEFF"), headers: true)
    assert_equal %w[id name email phone country state kind source referred_by_organization perfectbook_contact_id archived_at notes_count last_activity_at created_at updated_at],
      clients.headers
    assert_equal "Tashi", clients.first["name"]
    assert_equal "tashi@example.com", clients.first["email"]

    people = CSV.parse(files["people.csv"].delete_prefix("\uFEFF"), headers: true)
    assert_equal "Maya", people.first["name"]
    assert_includes people.headers, "lead_id"

    leads = CSV.parse(files["leads.csv"].delete_prefix("\uFEFF"), headers: true)
    assert_equal "Ad Lead", leads.first["name"]
    assert_equal "n8n-1", leads.first["external_ref"]

    organizations = CSV.parse(files["organizations.csv"].delete_prefix("\uFEFF"), headers: true)
    assert_equal "Ops Co", organizations.first["name"]

    notes = CSV.parse(files["notes.csv"].delete_prefix("\uFEFF"), headers: true)
    assert_equal "Loves Everest", notes.first["body"]
  end

  test "settings page offers the export" do
    get edit_settings_path
    assert_response :success
    assert_select "a[href=?]", settings_export_path, text: "Export everything"
  end
end
