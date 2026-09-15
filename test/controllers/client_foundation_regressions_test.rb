require "test_helper"
require_relative "../support/google_sign_in_test_helper"

class ClientFoundationRegressionsTest < ActionDispatch::IntegrationTest
  include GoogleSignInTestHelper

  setup { sign_in }

  test "linked contacts render in both client tabs" do
    Client.create!(name: "Traveler", perfectbook_contact_id: 123)
    Organization.create!(name: "Operator", perfectbook_contact_id: 456)
    [ [ "clients", 123 ], [ "organizations", 456 ] ].each do |tab, id|
      get clients_path(tab: tab)
      assert_response :success
      assert_select "a[href=?]", "https://perfectbook.sherpaholidays.com/contacts/#{id}"
    end
  end

  test "existing people leave room to append another person" do
    [ Client, Lead ].each do |model|
      record = model.create!(name: "Traveler")
      record.people.create!(name: "First")
      get polymorphic_path(record, action: :edit)
      assert_response :success
      key = model.model_name.param_key
      assert_select "input[name='#{key}[people_attributes][1][name]']"
      patch polymorphic_path(record), params: { key => { people_attributes: { "1" => { name: "Second" } } } }
      assert_response :redirect
      assert_equal %w[First Second], record.people.order(:id).pluck(:name)
    end
  end

  test "invalid tags return form errors and preserve saved tags" do
    [ Client, Lead, Organization ].each do |model|
      key = model.model_name.param_key
      invalid = "x" * 41
      assert_no_difference -> { model.count } do
        post polymorphic_path(model), params: { key => { name: "Invalid", tag_list: invalid } }
        assert_response :unprocessable_entity
      end
      record = model.create!(name: "Original", tag_list: "saved")
      patch polymorphic_path(record), params: { key => { name: "Changed", tag_list: invalid } }
      assert_response :unprocessable_entity
      assert_select "input[name='#{key}[tag_list]'][value=?]", invalid
      assert_equal "Original", record.reload.name
      assert_equal "saved", model.find(record.id).tag_list
    end
  end

  test "selected ordering replaces search activity ordering" do
    [ Client, Lead, Organization ].each do |model|
      model.create!(name: "Match Alpha")
      model.create!(name: "Match Zulu")
      path = model == Lead ? leads_path : clients_path
      get path, params: { q: "Match", sort: "name", tab: model == Organization ? "organizations" : nil }
      assert_response :success
      names = css_select("main a").map(&:text).map(&:strip).select { |name| name.start_with?("Match") }
      assert_equal [ "Match Alpha", "Match Zulu" ], names
    end
    Lead.create!(name: "Fit Strong", fit_score: 90)
    Lead.create!(name: "Fit Weak", fit_score: 10)
    get leads_path(q: "Fit", sort: "fit")
    names = css_select("main a").map(&:text).map(&:strip).select { |name| name.start_with?("Fit") }
    assert_equal [ "Fit Strong", "Fit Weak" ], names
  end

  test "older notes and events remain reachable" do
    [ Client, Lead, Organization ].each do |model|
      record = model.create!(name: "History")
      51.times { |i| record.notes.create!(body: "Note #{i}", created_at: i.minutes.ago) }
      51.times { |i| record.activity_events.create!(kind: "email", summary: "Email #{i}", occurred_at: i.days.ago) }
      get polymorphic_path(record)
      assert_select "a", text: "Older notes"
      assert_select "a", text: "Older activity"
      get polymorphic_path(record), params: { notes_page: 2, events_page: 2 }
      assert_response :success
      assert_select "p", text: "Note 50"
      assert_select "p", text: "Email 50"
    end
  end

  test "conversion preserves note events once and rejects stale conversion" do
    lead = Lead.create!(name: "Convert")
    note = lead.notes.create!(body: "History")
    stale = Lead.find(lead.id)
    client = lead.convert_to_client!
    events = client.activity_events.where(kind: "note")
    assert_equal 1, events.count
    assert_equal client.notes.first.id, events.first.metadata["note_id"]
    assert_equal note.id, lead.activity_events.where(kind: "note").first.metadata["note_id"]
    assert_no_difference -> { Client.count } do
      assert_raises(ActiveRecord::RecordInvalid) { stale.convert_to_client! }
    end
    assert_equal client.id, lead.reload.converted_client_id
  end

  test "display helpers use preloaded people and tags without queries" do
    [ Client, Lead ].each do |model|
      record = model.create!(name: "Emails", tag_list: "zulu, alpha")
      record.people.create!(name: "No email")
      record.people.create!(name: "Has email", email: "hello@example.com")
      loaded = model.includes(:people, :tags).find(record.id)
      queries = []
      callback = ->(*args) { queries << args.last[:sql] unless args.last[:name] == "SCHEMA" }
      ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
        assert_equal "hello@example.com", loaded.display_email
        assert_equal "alpha, zulu", loaded.tag_list
      end
      assert_empty queries
    end
  end
end
