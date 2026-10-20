require "test_helper"
require_relative "../support/google_sign_in_test_helper"
require_relative "../support/inquiry_mail_test_helper"

class LeadsRequestsTest < ActionDispatch::IntegrationTest
  include GoogleSignInTestHelper
  include InquiryMailTestHelper

  setup do
    sign_in
  end

  test "marking Potential from New removes the row and updates counts through the redirect" do
    lead = Lead.create!(name: "New traveler to review")
    other = Lead.create!(name: "New traveler still waiting")
    list_url = leads_path(tab: "new", q: "New traveler", sort: "name")
    get list_url
    assert_select "form[action='#{mark_potential_lead_path(lead)}'] button", text: "Mark Potential"
    assert_select "nav.tabs a", text: /New.*2/

    patch mark_potential_lead_path(lead), params: { return_to: list_url }, headers: { "HTTP_REFERER" => "https://evil.example/" }
    assert_redirected_to list_url
    follow_redirect!
    assert_select "h2", text: "New"
    assert_select "a", text: lead.name, count: 0
    assert_select "a", text: other.name
    assert_select "nav.tabs a", text: /New.*1/
    assert_select "nav.tabs a", text: /Potential.*1/
    assert_equal "new", lead.reload.status

    get leads_path
    assert_select "a", text: lead.name, count: 0
    get leads_path(tab: "potential", q: "New traveler", sort: "name")
    assert_select "a", text: lead.name
    assert_select "a", text: other.name, count: 0
    patch unmark_potential_lead_path(lead), params: { return_to: leads_path(tab: "potential") }
    follow_redirect!
    assert_select "a", text: lead.name, count: 0
    get list_url
    assert_select "a", text: lead.name
    assert_select "nav.tabs a", text: /New.*2/
    assert_select "nav.tabs a", text: /Potential.*0/
  end

  test "marking spam from New moves the row to Archived through the redirect" do
    lead = Lead.create!(name: "New spam inquiry")
    other = Lead.create!(name: "New genuine inquiry")
    get leads_path(tab: "new")
    assert_select "form[action='#{mark_as_spam_lead_path(lead)}'] button", text: "Mark as spam"
    list_url = leads_path(tab: "new", q: "New", sort: "name")
    patch mark_as_spam_lead_path(lead), params: { return_to: list_url }
    assert_redirected_to list_url
    follow_redirect!
    assert_select "h2", text: "New"
    assert_select "a", text: lead.name, count: 0
    assert_select "nav.tabs a", text: /New.*1/
    assert_select "nav.tabs a", text: /Archived.*1/
    assert_select ".flash-notice", text: /Marked as spam - moved to Archived.*Not spam/
    get leads_path(tab: "new", q: "New", sort: "name")
    assert_select "a", text: lead.name, count: 0
    assert_select "a", text: other.name
    patch not_spam_lead_path(lead), params: { return_to: leads_path(tab: "archived") }
    get leads_path(tab: "new")
    assert_select "a", text: lead.name
  end

  test "a lead page marking returns to its supplied Leads tab and unsafe targets fall back to New" do
    lead = Lead.create!(name: "Record action traveler", status: "quoted")
    return_to = leads_path(tab: "quoted", q: "traveler", sort: "newest")
    get lead_path(lead, return_to: return_to)
    assert_select "a[href=?]", return_to, text: "Leads"
    assert_select "form[action='#{mark_potential_lead_path(lead)}'] input[name=return_to][value=?]", return_to

    patch mark_potential_lead_path(lead), params: { return_to: return_to }
    assert_redirected_to return_to
    assert lead.reload.potential?

    other = Lead.create!(name: "Unsafe target traveler")
    patch mark_unsure_lead_path(other), params: { return_to: "https://evil.example/leads?tab=archived" },
      headers: { "HTTP_REFERER" => leads_url(tab: "quoted") }
    assert_redirected_to leads_path(tab: "new")
    assert other.reload.unsure?
  end

  test "changing a lead stage to Quoted returns to its originating list" do
    lead = Lead.create!(name: "Quote traveler")
    return_to = leads_path(tab: "new", q: "Quote", sort: "name")

    patch lead_path(lead), params: { return_to: return_to, lead: { status: "quoted" } }

    assert_redirected_to return_to
    assert_equal "quoted", lead.reload.status
    follow_redirect!
    assert_select "h2", text: "New"
    assert_select ".flash-notice", text: /Marked as Quoted - moved to Quoted/
  end

  test "stage changes archive and conversion move New leads to their own sections" do
    { "chatting" => "new", "nudged" => "new", "quoted" => "quoted", "lost" => "archived" }.each do |status, tab|
      lead = Lead.create!(name: "Move to #{status}")
      attrs = { status: status }
      attrs[:lost_reason] = "no_reply" if status == "lost"
      patch lead_path(lead), params: { lead: attrs }
      assert_redirected_to leads_path(tab: "new")
      (%w[new quoted archived] - [ tab ]).each do |other_tab|
        get leads_path(tab: other_tab)
        assert_select "a", text: lead.name, count: 0
      end
      get leads_path(tab: tab)
      assert_select "a", text: lead.name
    end

    archived = Lead.create!(name: "Move to archive")
    patch archive_lead_path(archived), params: { return_to: leads_path(tab: "new") }
    assert_redirected_to leads_path(tab: "new")
    follow_redirect!
    get leads_path(tab: "archived")
    assert_select "a", text: archived.name
    converted = Lead.create!(name: "Move to converted")
    post convert_lead_path(converted)
    assert_redirected_to client_path(converted.reload.converted_client)
    get leads_path(tab: "new")
    [ archived, converted ].each { |lead| assert_select "a", text: lead.name, count: 0 }
  end

  test "Potential actions keep stage membership and filter search and counts" do
    lead = Lead.create!(name: "Potential traveler", status: "quoted")
    other = Lead.create!(name: "General traveler")
    get lead_path(lead)
    assert_select "button", text: "Mark Potential"
    patch mark_potential_lead_path(lead)
    assert_redirected_to leads_path(tab: "new")
    assert lead.reload.potential?
    get leads_path(tab: "potential")
    assert_select "nav.tabs a", text: /Potential.*1/
    assert_select "a", text: lead.name
    assert_select "a", text: other.name, count: 0
    assert_select "button[aria-pressed=true]", text: "Remove Potential"
    get leads_path(tab: "quoted")
    assert_select "a", text: lead.name
    get leads_path(tab: "potential", q: "General")
    assert_select "a", text: lead.name, count: 0
    get leads_path(tab: "potential", q: "Potential", sort: "name")
    assert_select "a", text: lead.name
    patch unmark_potential_lead_path(lead), params: { return_to: leads_path(tab: "potential") }
    assert_redirected_to leads_path(tab: "potential")
    follow_redirect!
    assert_select ".empty", text: /No potential leads yet/
    assert_not lead.reload.potential?
    assert_equal "quoted", lead.status
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

  test "marking Potential enqueues AdConversions::LeadJob for reportable ad leads only" do
    ad_lead = Lead.create!(
      name: "Ad potential lead",
      metadata: {
        "attribution" => { "fbclid" => "IwAR-potential", "first_seen_at" => 1.day.ago.iso8601 },
        "acquisition" => { "permission" => { "state" => "allowed", "measurement" => true, "sharing" => true } }
      }
    )
    direct_lead = Lead.create!(name: "Direct potential lead")

    assert_enqueued_with(job: AdConversions::LeadJob, args: [ ad_lead.id ]) do
      patch mark_potential_lead_path(ad_lead)
    end
    assert_no_enqueued_jobs only: AdConversions::LeadJob do
      patch mark_potential_lead_path(direct_lead)
    end
  end

  test "spam action archives the inquiry and archived Not spam restores it" do
    lead = Lead.create!(name: "Spam inquiry")
    get lead_path(lead)
    assert_select "form[action='#{mark_as_spam_lead_path(lead)}'] button", text: "Mark as spam"
    patch mark_as_spam_lead_path(lead), params: { return_to: leads_path(tab: "new") }
    assert_redirected_to leads_path(tab: "new")
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
    patch not_spam_lead_path(lead), params: { return_to: leads_path(tab: "archived") }
    assert_redirected_to leads_path(tab: "archived")
    assert_not lead.reload.archived?
    assert_not lead.suspected_spam?
    get leads_path
    assert_select "a", text: lead.name
  end

  test "automatic flags offer confirm or not spam without changing scoring and show spam reason in Archived tab" do
    lead = Lead.create!(
      name: "Flagged inquiry",
      spam_score: 25,
      tag_list: Lead::SUSPECTED_SPAM_TAG,
      metadata: { "suspicion_hits" => [ "name_matches_email" ] }
    )
    get lead_path(lead)
    assert_select "section[aria-label='Spam review']", text: /Looks like spam \(Name matches email\)/
    assert_select "form[action='#{mark_as_spam_lead_path(lead)}'] button", text: "Mark as spam"
    assert_select "form[action='#{not_spam_lead_path(lead)}'] button", text: "Not spam"
    patch not_spam_lead_path(lead)
    assert_not lead.reload.suspected_spam?
    assert_not lead.archived?
    assert_equal 25, lead.spam_score
    get lead_path(lead)
    assert_select "section[aria-label='Spam review']", count: 0

    fast = Lead.create!(
      name: "Fast bot inquiry",
      spam_score: 50,
      archived_at: Time.current,
      spam_marked_at: Time.current,
      tag_list: Lead::SUSPECTED_SPAM_TAG,
      metadata: { "suspicion_hits" => [ "too_fast" ] }
    )
    get leads_path(tab: "archived")
    assert_select "li", text: /Fast bot inquiry.*Spam.*Submitted under 3s/m
    get lead_path(fast)
    assert_select "section[aria-label='Spam review']", text: /Marked as spam and archived \(Submitted under 3s\)/
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
    assert_equal %w[New Potential Unsure Quoted Archived],
      css_select("nav.tabs a").map { |tab| tab.at_css("span").text }
    assert_select "nav.tabs a", text: /New.*2/
    assert_select "a", text: "Chatty"
    assert_select "form input[name=q]"
  end

  test "retired stage tabs redirect to the tab that now holds those leads" do
    Lead.create!(name: "Newbie", source: "manual", status: "new")
    Lead.create!(name: "Lostie", source: "manual", status: "lost", lost_reason: "no_reply")
    get leads_path(tab: "lost", q: "ie", sort: "name")
    assert_redirected_to leads_path(q: "ie", sort: "name", tab: "archived")
    follow_redirect!
    assert_select "h2", text: "Archived"
    assert_select "a", text: "Lostie"
    assert_select "a", { text: "Newbie", count: 0 }
    assert_select "li", text: /Lost/
    assert_select "li button", text: "Restore", count: 0
    %w[chatting nudged].each do |tab|
      get leads_path(tab: tab)
      assert_redirected_to leads_path(tab: "new")
    end
  end

  test "Unsure moves leads out of New and back, and between Potential and spam" do
    lead = Lead.create!(name: "Voicemail traveler")
    other = Lead.create!(name: "Answering traveler")
    list_url = leads_path(tab: "new", q: "traveler", sort: "name")
    get list_url
    assert_select "form[action='#{mark_unsure_lead_path(lead)}'] button[aria-pressed=false]", text: "Mark Unsure"

    patch mark_unsure_lead_path(lead), params: { return_to: list_url }
    assert_redirected_to list_url
    follow_redirect!
    assert_select "a", text: lead.name, count: 0
    assert_select "a", text: other.name
    assert_select "nav.tabs a", text: /New.*1/
    assert_select "nav.tabs a", text: /Unsure.*1/
    assert_equal "new", lead.reload.status

    get leads_path(tab: "unsure")
    assert_select "h2", text: "Unsure"
    assert_select "a", text: lead.name
    assert_select "a", text: other.name, count: 0
    assert_select "li .badge", text: "Unsure"
    assert_select "button[aria-pressed=true]", text: "Remove Unsure"

    patch mark_potential_lead_path(lead)
    assert lead.reload.potential?
    assert_not lead.unsure?
    get leads_path(tab: "unsure")
    assert_select "a", text: lead.name, count: 0
    get leads_path(tab: "potential")
    assert_select "a", text: lead.name

    patch mark_unsure_lead_path(lead)
    assert lead.reload.unsure?
    assert_not lead.potential?
    get leads_path(tab: "potential")
    assert_select "a", text: lead.name, count: 0

    patch mark_as_spam_lead_path(lead)
    assert_nil lead.reload.unsure_marked_at
    get leads_path(tab: "unsure")
    assert_select "a", text: lead.name, count: 0
    get leads_path(tab: "archived")
    assert_select "a", text: lead.name
    patch mark_unsure_lead_path(lead)
    assert_redirected_to lead_path(lead)
    assert_nil lead.reload.unsure_marked_at

    patch not_spam_lead_path(lead)
    patch mark_unsure_lead_path(lead)
    assert lead.reload.unsure?
    patch unmark_unsure_lead_path(lead), params: { return_to: leads_path(tab: "unsure") }
    follow_redirect!
    assert_select ".empty", text: /No unsure leads/
    get list_url
    assert_select "a", text: lead.name
    assert_select "nav.tabs a", text: /New.*2/
  end

  test "suspected spam can wait in Unsure without a spam verdict" do
    lead = Lead.create!(name: "Maybe spam", tag_list: Lead::SUSPECTED_SPAM_TAG)
    get lead_path(lead)
    assert_select "button", text: "Mark Potential", count: 0
    assert_select "button", text: "Mark Unsure"
    patch mark_unsure_lead_path(lead)
    assert lead.reload.unsure?
    get leads_path(tab: "unsure")
    assert_select "li", text: /Looks like spam/
    assert_select "li button", text: "Not spam"
    get leads_path(tab: "new")
    assert_select "a", text: lead.name, count: 0
  end

  test "converted leads leave the Leads tabs and stay reachable from their client" do
    lead = Lead.create!(name: "Won", source: "manual", status: "quoted")
    client = lead.convert_to_client!
    get leads_path(tab: "converted", q: "Won", sort: "name")
    assert_redirected_to leads_path(q: "Won", sort: "name", tab: "new")
    follow_redirect!
    assert_select "h2", text: "New"
    assert_select "nav.tabs a", text: /Converted/, count: 0
    %w[new potential unsure quoted archived].each do |tab|
      get leads_path(tab: tab)
      assert_select "a", text: "Won", count: 0
    end
    get clients_path(q: "Won")
    assert_select "a[href=?]", client_path(client)
    get client_path(client)
    assert_select "a[href=?]", lead_path(lead), text: "open it"
    get lead_path(lead)
    assert_response :success
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
    assert_redirected_to leads_path(tab: "new")
    assert_equal "chatting", lead.reload.status
    assert lead.activity_events.exists?(kind: "stage_change")

    patch lead_path(lead), params: { lead: { name: "Staged", status: "lost" } }
    assert_response :unprocessable_entity
    assert_equal "chatting", lead.reload.status

    patch lead_path(lead), params: { lead: { name: "Staged", status: "lost", lost_reason: "dates" } }
    assert_redirected_to leads_path(tab: "new")
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

    patch archive_lead_path(lead), params: { return_to: leads_path(tab: "new") }
    assert_redirected_to leads_path(tab: "new")
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
    return_to = leads_path(tab: "archived", q: "Back", sort: "name")
    patch unarchive_lead_path(lead), params: { return_to: return_to }
    assert_redirected_to return_to
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
    assert_redirected_to leads_path(tab: "new")
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

  test "the composer on a website-copy safety-net lead addresses the visitor, not the copy's relay sender" do
    [ "crm@perfectcrm.sherpaholidays.com", "mailer@shopify.com" ].each do |relay|
      message = ingest_inquiry(from: relay, email: "visitor-#{relay.split("@").first}@example.com")
      Leads::UnlinkedInquiries.new.resolve!
      lead = message.conversation.reload.linkable

      get lead_path(lead)
      assert_response :success
      assert_select "input[name='message[to]'][value=?]", lead.email
      assert_select "[data-reply-box-target=recipientSummary]", lead.email
    end
  end
end
