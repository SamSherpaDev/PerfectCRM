require "test_helper"
require_relative "../support/google_sign_in_test_helper"

class LeadsRequestsTest < ActionDispatch::IntegrationTest
  include GoogleSignInTestHelper

  setup do
    sign_in
  end

  test "index renders tabs with counts and search" do
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
    Lead.create!(name: "Lostie", source: "manual", status: "lost", lost_reason: "no_reply")
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
    assert_select "section[aria-labelledby=timeline-heading]" do
      assert_select ".card-caption", text: "Every ask, score, note, and automation in one scroll, newest first."
      assert_select "textarea#message_body"
    end
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

  test "edit form stage changes run through Transition" do
    lead = Lead.create!(name: "Staged", source: "manual", status: "new")
    patch lead_path(lead), params: { lead: { name: "Staged", status: "chatting" } }
    assert_redirected_to lead_path(lead)
    assert_equal "chatting", lead.reload.status
    assert lead.activity_events.exists?(kind: "stage_change")

    patch lead_path(lead), params: { lead: { name: "Staged", status: "lost" } }
    assert_response :unprocessable_entity
    assert_equal "chatting", lead.reload.status

    patch lead_path(lead), params: { lead: { name: "Staged", status: "lost", lost_reason: "dates" } }
    assert_redirected_to lead_path(lead)
    assert_equal "lost", lead.reload.status
    assert_equal "dates", lead.lost_reason
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
  test "archive lists the lead under the archived tab" do
    lead = Lead.create!(name: "Deleteme", source: "manual", status: "new")

    patch archive_lead_path(lead)
    assert_redirected_to leads_path(tab: "archived")
    assert lead.reload.archived?

    get leads_path(tab: "new")
    assert_response :success
    assert_select "a", { text: "Deleteme", count: 0 }
    get leads_path(tab: "archived")
    assert_response :success
    assert_select "nav.tabs a", text: /Archived/
    assert_select "a", text: "Deleteme"
    assert_select "button", text: "Restore"
  end

  test "unarchive restores the previous stage" do
    lead = Lead.create!(name: "Back", source: "manual", status: "quoted")
    lead.archive!
    patch unarchive_lead_path(lead)
    assert_redirected_to lead_path(lead)
    assert_not lead.reload.archived?
    assert_equal "quoted", lead.status
    get leads_path(tab: "quoted")
    assert_select "a", text: "Back"
  end

  test "converted leads refuse archive" do
    lead = Lead.create!(name: "Won", source: "manual")
    lead.convert_to_client!
    patch archive_lead_path(lead)
    assert_redirected_to lead_path(lead)
    assert_not lead.reload.archived?
  end

  test "restore is refused while an open lead holds the same email" do
    old = Lead.create!(name: "Old", source: "manual", email: "reuse@example.com")
    old.archive!
    Lead.create!(name: "New", source: "manual", email: "reuse@example.com")
    patch unarchive_lead_path(old)
    assert_redirected_to lead_path(old)
    assert old.reload.archived?
    follow_redirect!
    assert_select ".flash-alert", text: /Email has already been taken/
  end

  test "archived lead page hides working actions and offers restore" do
    lead = Lead.create!(name: "Archie", source: "manual", status: "new")
    lead.archive!
    get lead_path(lead)
    assert_response :success
    assert_select "p.eyebrow", text: "Lead · Archived"
    assert_select "div", text: /Archived on/
    assert_select "button", text: "Restore"
    assert_select "a", { text: "Edit", count: 0 }
    assert_select "button", { text: /Convert to client/, count: 0 }
    assert_select "button", { text: "Delete", count: 0 }
  end

  test "show names the lead in the delete confirmation" do
    lead = Lead.create!(name: "Deleteme", source: "manual")
    get lead_path(lead)
    assert_response :success
    assert_select "form[data-turbo-confirm*=?]", "Delete Deleteme?"
  end

  test "edit and convert are blocked while archived" do
    lead = Lead.create!(name: "Archie", source: "manual", status: "new")
    lead.archive!
    get edit_lead_path(lead)
    assert_redirected_to lead_path(lead)
    patch lead_path(lead), params: { lead: { name: "Changed" } }
    assert_redirected_to lead_path(lead)
    assert_equal "Archie", lead.reload.name
    post convert_lead_path(lead)
    assert_redirected_to lead_path(lead)
    assert_not lead.reload.converted?
  end

  test "fit labels and bars use the supplied band" do
    lead = Lead.create!(name: "Panda", fit_score: 80, fit_band: "possible")
    [ leads_path, lead_path(lead) ].each do |path|
      get path
      assert_response :success
      assert_select ".bar-warn", count: 1
      assert_select "span", text: "Possible · 80"
      assert_select ".stat", count: 0
    end
    lead.update!(fit_score: nil, fit_band: "strong")
    get lead_path(lead)
    assert_select "span", text: "Strong"
    assert_select ".bar-good", count: 1
  end
end
