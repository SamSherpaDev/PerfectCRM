require "test_helper"
require_relative "../support/google_sign_in_test_helper"

class LeadsRequestsTest < ActionDispatch::IntegrationTest
  include GoogleSignInTestHelper

  setup do
    sign_in
  end

  test "index renders tiles, tabs with counts, and search" do
    Lead.create!(name: "Ad One", source: "google_ads", status: "new")
    Lead.create!(name: "Chatty", source: "manual", status: "chatting")
    get leads_path
    assert_response :success
    assert_select "h1", "Leads"
    assert_select "nav.tabs a", text: /New/
    assert_select "nav.tabs a", text: /Chatting/
    assert_select "nav.tabs a", text: /Quoted/
    assert_select "nav.tabs a", text: /Nudged/
    assert_select "nav.tabs a", text: /Lost/
    assert_select "nav.tabs a", text: /Converted/
    assert_select "form input[name=q]"
  end

  test "index tabs filter by status" do
    Lead.create!(name: "Newbie", source: "manual", status: "new")
    Lead.create!(name: "Lostie", source: "manual", status: "lost")
    get leads_path(tab: "lost")
    assert_response :success
    assert_select "a", text: "Lostie"
    assert_select "a", { text: "Newbie", count: 0 }
  end

  test "converted tab lists converted leads" do
    lead = Lead.create!(name: "Won", source: "manual", status: "quoted")
    lead.convert_to_client!
    get leads_path(tab: "converted")
    assert_response :success
    assert_select "a", text: "Won"
  end

  test "show renders facts, fit, notes, timeline, and convert" do
    lead = Lead.create!(
      name: "Ad Lead", source: "google_ads", campaign_name: "Everest",
      fit_score: 82, fit_band: "strong", status: "new"
    )
    get lead_path(lead)
    assert_response :success
    assert_select "h1", "Ad Lead"
    assert_select "button", text: /Convert to client/
    assert_select "h2", text: "Facts"
    assert_select "h2", text: "Timeline"
    assert_select "p", text: /Conversations will appear here once mail is connected/
  end

  test "show of a converted lead is read-only with a forward link" do
    lead = Lead.create!(name: "Ad", source: "manual")
    client = lead.convert_to_client!
    get lead_path(lead)
    assert_response :success
    assert_select "a", text: "Open client"
    assert_select "button", { text: /Convert to client/, count: 0 }
    assert_select "a", { text: "Edit", count: 0 }
    assert_select "div", text: /Converted leads stay read-only/
  end

  test "client page shows lead origin" do
    lead = Lead.create!(name: "Ad", source: "google_ads", campaign_name: "Everest")
    client = lead.convert_to_client!
    get client_path(client)
    assert_response :success
    assert_select "div", text: /Started as a lead/
    assert_select "a", text: "Open the lead"
  end

  test "new and create with person and tags" do
    get new_lead_path
    assert_response :success
    post leads_path, params: {
      lead: {
        name: "Ad Lead", source: "google_ads", campaign_name: "Everest",
        status: "new", tag_list: "everest",
        people_attributes: [ { name: "Maya", role: "spouse" } ]
      }
    }
    assert_redirected_to lead_path(Lead.last)
    assert_equal "everest", Lead.last.tags.first.name
    assert_equal "Maya", Lead.last.people.first.name
  end

  test "convert creates a client and freezes the lead" do
    lead = Lead.create!(name: "Ad", source: "manual")
    assert_difference -> { Client.count }, 1 do
      post convert_lead_path(lead)
    end
    assert_redirected_to client_path(Client.last)
    assert lead.reload.converted?
    assert_select_button_missing = true
  end

  test "convert is blocked twice" do
    lead = Lead.create!(name: "Ad", source: "manual")
    post convert_lead_path(lead)
    assert_redirected_to client_path(Client.last)
    post convert_lead_path(lead)
    assert_redirected_to lead_path(lead)
  end

  test "edit is blocked after conversion" do
    lead = Lead.create!(name: "Ad", source: "manual")
    lead.convert_to_client!
    get edit_lead_path(lead)
    assert_redirected_to lead_path(lead)
    patch lead_path(lead), params: { lead: { name: "Changed" } }
    assert_redirected_to lead_path(lead)
    assert_equal "Ad", lead.reload.name
  end

  test "notes are blocked after conversion" do
    lead = Lead.create!(name: "Ad", source: "manual")
    lead.convert_to_client!
    assert_no_difference -> { lead.notes.count } do
      post lead_notes_path(lead), params: { note: { body: "Late note" } }
    end
    assert_redirected_to lead_path(lead)
  end
end
