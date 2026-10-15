require "test_helper"
require_relative "../support/google_sign_in_test_helper"

class LeadsRequestsTest < ActionDispatch::IntegrationTest
  include GoogleSignInTestHelper

  setup do
    sign_in
  end

  test "Potential actions keep stage membership and filter search and counts" do
    lead = Lead.create!(name: "Potential traveler", status: "chatting")
    other = Lead.create!(name: "General traveler")
    get lead_path(lead)
    assert_select "button", text: "Mark Potential"
    patch mark_potential_lead_path(lead)
    assert_redirected_to lead_path(lead)
    assert lead.reload.potential?
    get leads_path(tab: "potential")
    assert_select "nav.tabs a", text: /Potential.*1/
    assert_select "a", text: lead.name
    assert_select "a", text: other.name, count: 0
    assert_select "button[aria-pressed=true]", text: "Remove Potential"
    get leads_path(tab: "chatting")
    assert_select "a", text: lead.name
    get leads_path(tab: "potential", q: "General")
    assert_select "a", text: lead.name, count: 0
    get leads_path(tab: "potential", q: "Potential", sort: "name")
    assert_select "a", text: lead.name
    patch unmark_potential_lead_path(lead), headers: { "HTTP_REFERER" => leads_url(tab: "potential") }
    assert_redirected_to leads_path(tab: "potential")
    follow_redirect!
    assert_select ".empty", text: /No potential leads yet/
    assert_not lead.reload.potential?
    assert_equal "chatting", lead.status
  end

  test "Potential endpoints refuse archived converted and suspected spam inquiries" do
    archived = Lead.create!(name: "Archived", archived_at: Time.current)
    converted = Lead.create!(name: "Converted")
    converted.convert_to_client!
    flagged = Lead.create!(name: "Flagged", tag_list: Lead::SUSPECTED_SPAM_TAG)
    [ archived, converted, flagged ].each do |lead|
      get lead_path(lead)
      assert_select "button", text: "Mark Potential", count: 0
      patch mark_potential_lead_path(lead)
      assert_redirected_to lead_path(lead)
      assert_nil lead.reload.potential_marked_at
    end
  end

  test "spam action archives the inquiry and archived Not spam restores it" do
    lead = Lead.create!(name: "Spam inquiry")
    get lead_path(lead)
    assert_select "form[action='#{mark_as_spam_lead_path(lead)}'] button", text: "Mark as spam"
    patch mark_as_spam_lead_path(lead)
    assert_redirected_to leads_path(tab: "archived")
    assert lead.reload.archived?
    assert lead.spam_marked_at.present?
    get leads_path
    assert_select "a", text: lead.name, count: 0
    get leads_path(tab: "archived")
    assert_select "a", text: lead.name
    assert_select "form[action='#{not_spam_lead_path(lead)}'] button", text: "Not spam"
    get lead_path(lead)
    assert_select "section[aria-label='Spam review']", text: /Marked as spam and archived/
    assert_select "form[action='#{not_spam_lead_path(lead)}'] button", text: "Not spam"
    patch not_spam_lead_path(lead)
    assert_redirected_to lead_path(lead)
    assert_not lead.reload.archived?
    assert_not lead.suspected_spam?
    get leads_path
    assert_select "a", text: lead.name
  end

  test "automatic flags offer confirm or not spam without changing scoring" do
    lead = Lead.create!(name: "Flagged inquiry", spam_score: 75, tag_list: Lead::SUSPECTED_SPAM_TAG)
    get lead_path(lead)
    assert_select "section[aria-label='Spam review']", text: /Looks like spam/
    assert_select "form[action='#{mark_as_spam_lead_path(lead)}'] button", text: "Mark as spam"
    assert_select "form[action='#{not_spam_lead_path(lead)}'] button", text: "Not spam"
    patch not_spam_lead_path(lead)
    assert_not lead.reload.suspected_spam?
    assert_not lead.archived?
    assert_equal 75, lead.spam_score
    get lead_path(lead)
    assert_select "section[aria-label='Spam review']", count: 0
  end

  test "converted inquiry spam endpoints preserve the client and inquiry" do
    lead = Lead.create!(name: "Converted inquiry")
    client = lead.convert_to_client!
    [ mark_as_spam_lead_path(lead), not_spam_lead_path(lead) ].each do |path|
      patch path
      assert_redirected_to lead_path(lead)
      assert_not lead.reload.archived?
      assert_nil lead.spam_marked_at
      assert_equal client, lead.converted_client
    end
  end

  test "an archived automatic flag can still be confirmed or cleared" do
    lead = Lead.create!(name: "Archived flag", tag_list: Lead::SUSPECTED_SPAM_TAG, archived_at: Time.current)
    get lead_path(lead)
    assert_select "section[aria-label='Spam review']", text: /Confirm your verdict/
    assert_select "form[action='#{mark_as_spam_lead_path(lead)}'] button", text: "Mark as spam"
    assert_select "form[action='#{not_spam_lead_path(lead)}'] button", text: "Not spam"
    patch mark_as_spam_lead_path(lead)
    assert lead.reload.spam_marked_at.present?
    assert lead.archived?
  end

  test "manual forms and requests cannot assign referral codes" do
    get new_lead_path
    assert_response :success
    assert_select "input[name='lead[referral_code]']", count: 0
    post leads_path, params: { lead: { name: "Manual", referral_code: "KQ7X2D" } }
    record = Lead.order(:id).last
    assert_redirected_to lead_path(record)
    assert_nil record.referral_code
    record.update!(referral_code: "AAAA22")
    get edit_lead_path(record)
    assert_response :success
    assert_select "input[name='lead[referral_code]']", count: 0
    [ "BBBB33", "" ].each do |code|
      patch lead_path(record), params: { lead: { name: "Updated", referral_code: code } }
      assert_redirected_to lead_path(record)
      assert_equal "AAAA22", record.reload.referral_code
      assert_equal "Updated", record.name
    end
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
    assert_select "h2", text: "Details"
    assert_select "h2", text: "Timeline"
    assert_select "h2", { text: "Facts", count: 0 }
    assert_select "section[aria-labelledby=timeline-heading]" do
      assert_select ".card-caption", text: "Every email, note, quote, and automated step in one scroll."
    end
    assert_select "textarea#message_body"
    assert_select "textarea#note_body"
  end

  test "inquiry and converted client show raw phone when parsing fails" do
    lead = Lead.create!(name: "Synthetic", phone_raw: "ask for Alex at reception")
    get lead_path(lead)
    assert_response :success
    assert_select "dt", text: "Phone"
    assert_select "dd", text: "ask for Alex at reception"

    client = lead.convert_to_client!
    get client_path(client)
    assert_response :success
    assert_select "dt", text: "Phone"
    assert_select "dd", text: "ask for Alex at reception"
    client.update!(phone: "+14155550134")
    get client_path(client)
    assert_response :success
    assert_select "dd", text: "+14155550134"
    assert_select "dd", text: "ask for Alex at reception", count: 0
  end

  test "show renders the referral code" do
    lead = Lead.create!(name: "Referred", source: "website_form", referral_code: "KQ7X2D")
    get lead_path(lead)
    assert_response :success
    assert_select "dt", text: "Referral code"
    assert_select "dd", text: "KQ7X2D"
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
    assert_select "a", text: "open it"
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

  test "restore succeeds while an open lead holds the same email" do
    old = Lead.create!(name: "Old", source: "manual", email: "reuse@example.com")
    old.archive!
    Lead.create!(name: "New", source: "manual", email: "reuse@example.com")
    patch unarchive_lead_path(old)
    assert_redirected_to lead_path(old)
    assert_not old.reload.archived?
    follow_redirect!
    assert_select ".flash-notice", text: /restored/i
  end

  test "restore is refused while an open lead holds the same PerfectBook link" do
    old = Lead.create!(name: "Old", source: "manual", perfectbook_contact_id: 321)
    old.archive!
    Lead.create!(name: "New", source: "manual", perfectbook_contact_id: 321)
    patch unarchive_lead_path(old)
    assert_redirected_to lead_path(old)
    assert old.reload.archived?
    follow_redirect!
    assert_select ".flash-alert", text: /already been taken/
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
    get leads_path
    assert_response :success
    assert_select ".bar-warn", count: 1
    assert_select "span", text: "Possible · 80"
    assert_select ".stat", count: 0
    get lead_path(lead)
    assert_response :success
    assert_select ".bar-warn", count: 1
    assert_select ".fit-word", text: /Possible fit/
    assert_select ".fit-word .num", text: "80"
    assert_select ".stat", count: 0
    lead.update!(fit_score: nil, fit_band: "strong")
    get lead_path(lead)
    assert_select ".fit-word", text: /Strong fit/
    assert_select ".bar-good", count: 1
  end

  test "unscored inquiry offers audited owner fit choices without setting AI fit or stage" do
    lead = Lead.create!(name: "Unscored inquiry")
    get lead_path(lead)
    assert_select ".fit-word", text: "Not scored yet"
    assert_select "#owner-fit-heading", text: "Set your fit"
    assert_select "button[name='lead[owner_fit_at_inquiry]']", count: 3

    Lead::FIT_BANDS.each do |band|
      patch lead_path(lead), params: { lead: { owner_fit_at_inquiry: band } }
      assert_redirected_to lead_path(lead)
      lead.reload
      assert_equal band, lead.owner_fit_at_inquiry
      assert_equal "CAPTAIN@gmail.com", lead.owner_fit_recorded_by
      assert_not_nil lead.owner_fit_recorded_at
      assert_equal band, lead.activity_events.where(kind: "inquiry_fit").order(:id).last.metadata["fit"]
      assert_nil lead.fit_band
      assert_nil lead.fit_score
      assert_equal "new", lead.status
      follow_redirect!
      assert_select ".fit-word", text: "Not scored yet"
      assert_select "#owner-fit-heading", text: "Your fit at inquiry: #{band.humanize}"
      assert_select "button[value='#{band}'][aria-pressed='true']", count: 1
    end
  end

  test "owner fit preserves an existing AI verdict" do
    lead = Lead.create!(name: "Scored inquiry", fit_band: "strong", fit_score: 84, fit_reason: "Good trip match")
    patch lead_path(lead), params: { lead: { owner_fit_at_inquiry: "weak" } }
    follow_redirect!
    assert_select ".fit-word", text: /Strong fit/
    assert_select ".fit-word .num", text: "84"
    assert_select ".fit-why", text: "Good trip match"
    assert_select "#owner-fit-heading", text: "Your fit at inquiry: Weak"
    assert_equal [ "strong", 84, "Good trip match" ], lead.reload.attributes.values_at("fit_band", "fit_score", "fit_reason")
  end

  test "archived and converted inquiries show owner fit without editable choices" do
    archived = Lead.create!(name: "Archived inquiry", owner_fit_at_inquiry: "possible")
    archived.archive!
    converted = Lead.create!(name: "Converted inquiry", owner_fit_at_inquiry: "possible")
    converted.convert_to_client!

    [ archived, converted ].each do |lead|
      get lead_path(lead)
      assert_select "#owner-fit-heading", text: "Your fit at inquiry: Possible"
      assert_select "button[name='lead[owner_fit_at_inquiry]']", count: 0
      patch lead_path(lead), params: { lead: { owner_fit_at_inquiry: "strong" } }
      assert_redirected_to lead_path(lead)
      assert_equal "possible", lead.reload.owner_fit_at_inquiry
    end
  end
end
