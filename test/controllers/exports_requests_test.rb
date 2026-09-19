require "test_helper"
require_relative "../support/google_sign_in_test_helper"

class ExportsRequestsTest < ActionDispatch::IntegrationTest
  include GoogleSignInTestHelper

  setup do
    sign_in
  end

  test "export streams a zip of eight csv files with a bom" do
    org = Organization.create!(name: "Ops Co", kind: "operator", email: "ops@example.com")
    archived = Lead.create!(name: "Archived Lead", source: "manual")
    archived.archive!
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

    assert_equal %w[activity_events.csv clients.csv leads.csv notes.csv organizations.csv people.csv taggings.csv tags.csv], files.keys.sort
    files.each_value do |content|
      assert content.start_with?("\uFEFF"), "expected a UTF-8 BOM for Excel"
    end

    clients = CSV.parse(files["clients.csv"].delete_prefix("\uFEFF"), headers: true)
    assert_equal %w[id name email phone country state kind source campaign_name referred_by_organization perfectbook_contact_id pipeline_stage archived_at notes_count last_activity_at created_at updated_at],
      clients.headers
    assert_equal "Tashi", clients.first["name"]
    assert_equal "tashi@example.com", clients.first["email"]

    people = CSV.parse(files["people.csv"].delete_prefix("\uFEFF"), headers: true)
    assert_equal "Maya", people.first["name"]
    assert_includes people.headers, "lead_id"

    leads = CSV.parse(files["leads.csv"].delete_prefix("\uFEFF"), headers: true)
    ad_row = leads.find { |row| row["name"] == "Ad Lead" }
    assert_equal "n8n-1", ad_row["external_ref"]
    assert_nil ad_row["archived_at"]
    archived_row = leads.find { |row| row["name"] == "Archived Lead" }
    assert_equal archived.archived_at.iso8601, archived_row["archived_at"]

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
  test "export includes tag ownership and events and escapes formula cells" do
    client = Client.create!(name: "=SUM(1,2)", phone: "+1-415-555-0134", tag_list: "@tag", campaign_name: "-campaign")
    lead = Lead.create!(name: "+Lead")
    Organization.create!(name: "-Operator")
    client.people.create!(name: "@Person")
    note = Note.create!(notable: client, body: "=1+1")
    event = ActivityEvent.create!(subject: lead, kind: "automation", summary: "@event", occurred_at: Time.current, metadata: { "source" => "Panda" })
    get settings_export_path
    assert_response :success
    tables = {}
    Zip::InputStream.open(StringIO.new(response.body)) do |zip|
      while (entry = zip.get_next_entry)
        tables[entry.name] = CSV.parse(zip.read.force_encoding(Encoding::UTF_8).delete_prefix("\uFEFF"), headers: true)
      end
    end
    assert_equal "'=SUM(1,2)", tables["clients.csv"].first["name"]
    assert_equal "'+1-415-555-0134", tables["clients.csv"].first["phone"]
    assert_equal "'-campaign", tables["clients.csv"].first["campaign_name"]
    assert_equal "'+Lead", tables["leads.csv"].first["name"]
    assert_equal "'-Operator", tables["organizations.csv"].first["name"]
    assert_equal "'@Person", tables["people.csv"].first["name"]
    assert_equal "'=1+1", tables["notes.csv"].find { |row| row["id"] == note.id.to_s }["body"]
    tag = tables["tags.csv"].first
    assert_equal "'@tag", tag["name"]
    assignment = tables["taggings.csv"].first
    assert_equal tag["id"], assignment["tag_id"]
    assert_equal "Client", assignment["taggable_type"]
    assert_equal client.id.to_s, assignment["taggable_id"]
    exported_event = tables["activity_events.csv"].find { |row| row["id"] == event.id.to_s }
    assert_equal "'@event", exported_event["summary"]
    assert_equal "Lead", exported_event["subject_type"]
    assert_equal lead.id.to_s, exported_event["subject_id"]
    assert_equal event.metadata, JSON.parse(exported_event["metadata"])
  end

  test "export preserves website inquiry and follow-up answers" do
    settings = Setting.current.ensure_intake_credentials!
    headers = {
      "CONTENT_TYPE" => "application/json",
      "Origin" => "https://www.sherpaholidays.com",
      "X-Sherpa-Site-Key" => settings.site_key
    }
    submission_id = SecureRandom.uuid
    post "/api/v1/leads/intake", params: JSON.generate({
      schema: "sherpa.inquiry.v2", submission_id: submission_id,
      contact: { name: "Anna Lindqvist", email: "anna@example.com", phone_raw: "+1 415 555 0134" },
      trip: { handle: "private-nepal-tour", title: "Private Nepal tour" },
      message: "=Two travelers, \"spring\"\nFlexible dates", placement: "landing",
      consent: { contact: true, contact_at: "2026-09-14T18:06:40Z", text_version: "2026-09-v2" },
      attribution: { gclid: "click-id", utm_campaign: "nepal-2027" },
      page: { url: "https://www.sherpaholidays.com/contact?gclid=click-id" }
    }), headers: headers
    assert_response :accepted
    lead = Lead.find(response.parsed_body["id"])

    post "/api/v1/leads/intake/details", params: JSON.generate({
      schema: "sherpa.inquiry.details.v1", submission_id: submission_id,
      trip: { month: 4, year: 2027, timing_unknown: false, budget_band: "4000_7000" },
      party: { size: 2 }
    }), headers: headers
    assert_response :ok
    lead.reload

    get settings_export_path
    assert_response :success
    rows = nil
    Zip::InputStream.open(StringIO.new(response.body)) do |zip|
      while (entry = zip.get_next_entry)
        if entry.name == "leads.csv"
          rows = CSV.parse(zip.read.force_encoding(Encoding::UTF_8).delete_prefix("\uFEFF"), headers: true)
        end
      end
    end
    row = rows.find { |record| record["id"] == lead.id.to_s }
    expected = {
      "phone_raw" => "'+1 415 555 0134", "trip_handle" => "private-nepal-tour",
      "trip_title" => "Private Nepal tour", "message" => "'#{lead.message}",
      "consent_contact_at" => "2026-09-14T11:06:40-07:00", "consent_text_version" => "2026-09-v2",
      "placement" => "landing", "travel_month" => "4", "travel_year" => "2027",
      "timing_unknown" => "false", "party_size" => "2", "budget_band" => "4000_7000",
      "spam_score" => "0", "received_at" => lead.received_at.iso8601, "reference" => lead.reference
    }
    expected.each { |column, value| assert_equal value, row[column], "exported #{column}" }
    assert_equal lead.metadata, JSON.parse(row["metadata"])
    assert_equal "click-id", JSON.parse(row["metadata"]).dig("attribution", "gclid")
  end
end
