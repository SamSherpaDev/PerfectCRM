require "application_system_test_case"
require_relative "../support/google_sign_in_test_helper"
require_relative "../../db/migrate/20261006020537_refresh_default_first_reply"

class TemplateSubjectFallbackSystemTest < ApplicationSystemTestCase
  include GoogleSignInTestHelper

  setup do
    @lead = Lead.create!(name: "Tashi Sherpa", email: "tashi@example.com", source: "manual")
    @template = Template.create!(name: "Trip follow-up", purpose: :itinerary_follow_up,
      subject: "Hi {{first_name}}, your {{trip}}", body: "Hi {{first_name}}, checking in about {{trip}}.")
    OmniAuth.config.mock_auth[:google_oauth2] = OmniAuth::AuthHash.new(
      provider: "google_oauth2", uid: "google-captain",
      extra: { id_token: JWT.encode(@claims, @key, "RS256") })
    Google::Auth::IDTokens.stub(:oidc_key_source, @source) do
      visit "/auth/google_oauth2/callback"
      assert_selector "h1", text: "Today"
    end
    page.current_window.resize_to(1400, 1000)
  end

  test "lead template fallback survives saving and sending while known trips stay personal" do
    visit lead_path(@lead)
    open_details
    click_button "Trip follow-up", match: :first
    assert_field "Subject", with: "Hi Tashi, your Nepal trip"
    assert_field "Message", with: "Hi Tashi, checking in about Nepal trip."
    capture("lead-fallback")
    click_button "Save draft"
    assert_text "Draft saved"
    visit lead_path(@lead)
    open_details
    assert_field "Subject", with: "Hi Tashi, your Nepal trip"
    click_button "Send"
    assert_text "Sending your reply"
    assert_equal "Hi Tashi, your Nepal trip", Message.last.subject
    assert_includes Message.last.text_body, "Nepal trip"
    assert_not_includes Message.last.text_body, "[missing: trip]"

    @lead.update!(trip_interest: "Annapurna")
    visit lead_path(@lead, new_thread: 1)
    open_details
    fill_in "Message", with: ""
    click_button "Trip follow-up", match: :first
    assert_field "Subject", with: "Hi Tashi, your Annapurna"
    assert_field "Message", with: "Hi Tashi, checking in about Annapurna."
    capture("lead-personalized")

    @template.update!(subject: "Hello {{nickname}}")
    visit lead_path(@lead, new_thread: 1)
    open_details
    fill_in "Message", with: ""
    click_button "Trip follow-up", match: :first
    assert_field "Subject", with: "Planning your trip"
    @template.update!(subject: "Hello from SherpaHolidays")
    visit lead_path(@lead, new_thread: 1)
    open_details
    fill_in "Message", with: ""
    click_button "Trip follow-up", match: :first
    assert_field "Subject", with: "Hello from SherpaHolidays"
  end

  test "pipeline and task nudges and organization mailto use friendly subjects" do
    task = @lead.tasks.create!(title: "Follow up", due_on: Date.current, template: @template)
    [ { nudge: 1 }, { task: task.id } ].each do |params|
      visit lead_path(@lead, **params.merge(template: @template.id))
      open_details
      assert_field "Subject", with: "Hi Tashi, your Nepal trip"
      assert_field "Message", with: "Hi Tashi, checking in about Nepal trip."
    end
    capture("task-nudge")
    organization = Organization.create!(name: "Adventure Co.", email: "advisor@example.com")
    task = organization.tasks.create!(title: "Follow up", due_on: Date.current, template: @template)
    visit organization_path(organization, task: task.id, template: @template.id)
    mailto = URI.parse(all('a[href^="mailto:"]').last[:href])
    query = URI.decode_www_form(mailto.opaque.split("?", 2).last).to_h
    assert_equal "Planning your trip", query["subject"]
    assert_includes query["body"], "[missing: trip]"
    capture("organization-nudge")
  end

  test "document requests with and without a template fall back when booking trip is missing" do
    @client = Client.create!(name: "Tashi Sherpa", email: "client@example.com", perfectbook_contact_id: 7301)
    booking = PerfectBook::Booking.create!(perfectbook_id: 7302, perfectbook_contact_id: 7301,
      ref: "BK-7302", synced_at: Time.current, missing_count: 1,
      documents_json: { "travelers" => [ { "id" => 1, "first_name" => "Tashi",
        "documents" => [ { "type" => "visa", "status" => "missing" } ] } ] })
    Template.active.for_purpose(:document_request).update_all(archived_at: Time.current)
    template = Template.create!(name: "Documents", purpose: :document_request,
      subject: "Documents for {{trip}}", body: "Hi {{first_name}}, for {{trip}} we need {{missing_documents}}.")
    [ true, false ].each do |with_template|
      template.archive! unless with_template
      visit document_nudge_path(booking_id: booking.id)
      assert_field "Subject", with: "Planning your trip"
      assert_includes find_field("Message").value, "Tashi: visa"
      capture("documents-#{with_template}")
      click_link "Open in reply box"
      open_details
      assert_field "Subject", with: "Planning your trip"
      booking.update!(trip_name: "Annapurna")
      visit document_nudge_path(booking_id: booking.id)
      assert_field "Subject", with: "Documents for Annapurna"
      booking.update!(trip_name: nil)
    end
  end

  test "searched picker falls back for blank trip values and preserves body warnings" do
    @lead.update!(trip_interest: " ")
    visit lead_path(@lead)
    open_details
    find(".reply-templates > summary").click
    within(".reply-templates") do
      find("input[name=q]").set("Trip follow-up")
      assert_selector "input[name=q][value='Trip follow-up']"
      click_button "Insert"
    end
    assert_field "Subject", with: "Hi Tashi, your Nepal trip"
    assert_field "Message", with: "Hi Tashi, checking in about Nepal trip."
    capture("searched-picker-fallback")
  end

  test "website first reply stays personal through saving sending conversion and group preview" do
    seed_first_reply
    @lead.update!(trip_title: "18-Day Everest Base Camp Premium Trek", source: "website_form")
    visit lead_path(@lead)
    insert_first_reply
    assert_first_reply("18-Day Everest Base Camp Premium Trek")
    capture("inquiry-first-reply")
    click_button "Save draft"
    assert_text "Draft saved"
    visit lead_path(@lead)
    open_details
    assert_first_reply("18-Day Everest Base Camp Premium Trek")
    click_button "Send"
    assert_text "Sending your reply"
    assert_equal "Planning your 18-Day Everest Base Camp Premium Trek", Message.last.subject
    assert_includes Message.last.text_body, "Would you be open to a short call?"
    client = @lead.convert_to_client!
    Lead.create!(name: "Other traveler", email: "other@example.test", trip_title: "Other trip",
      converted_client: client, converted_at: Time.current, received_at: 1.hour.from_now)
    visit client_path(client, new_thread: 1)
    insert_first_reply
    assert_first_reply("18-Day Everest Base Camp Premium Trek")
    capture("converted-inquiry-first-reply")
    visit merge_templates_path
    select "First reply to a new inquiry", from: "Template"
    fill_in "Recipients", with: "Tashi Sherpa <tashi@example.com>"
    click_button "Preview merge"
    within("[aria-label='Merged messages']") do
      assert_text "Planning your 18-Day Everest Base Camp Premium Trek"
      assert_text "Would you be open to a short call?"
      assert_no_text "Other trip"
      assert_no_text "[missing: trip]"
    end
    find("[aria-label='Merged messages']").scroll_to(:top)
    capture("inquiry-group-preview")
  end

  test "undecided inquiries use neutral wording while unrelated clients retain missing data" do
    seed_first_reply
    [ "Not sure yet", " " ].each do |trip|
      @lead.update!(trip_title: trip)
      visit lead_path(@lead, new_thread: 1)
      insert_first_reply
      assert_first_reply("Nepal trip")
      capture("undecided-inquiry-#{trip.strip.empty? ? 'blank' : 'unsure'}")
    end
    client = Client.create!(name: "Unknown Traveler", email: "unknown@example.test")
    Lead.create!(name: "Other traveler", email: "other@example.test", trip_title: "Not sure yet",
      converted_client: client, converted_at: Time.current)
    visit client_path(client)
    insert_first_reply
    assert_field "Subject", with: "Planning your trip"
    assert_includes find_field("Message").value, "[missing: trip]"
    capture("unrelated-client-missing-trip")
    visit merge_templates_path
    select "First reply to a new inquiry", from: "Template"
    fill_in "Recipients", with: "Unknown Traveler <unknown@example.test>"
    click_button "Preview merge"
    within("[aria-label='Merged messages']") do
      assert_text "Missing: trip"
      assert_no_text "Nepal trip"
    end
    find("[aria-label='Merged messages']").scroll_to(:top)
    capture("unrelated-group-missing-trip")
  end

  test "upgrade refreshes default first reply while preserving captain copy" do
    seed_first_reply
    template = Template.find_by!(name: RefreshDefaultFirstReply::NAME)
    template.update!(body: RefreshDefaultFirstReply::OLD_BODY)
    custom = Template.create!(name: RefreshDefaultFirstReply::NAME, purpose: :first_reply,
      subject: "My welcome", body: "Hi {{first_name}}, my own welcome.")
    ActiveRecord::Migration.suppress_messages { RefreshDefaultFirstReply.new.migrate(:up) }
    visit edit_template_path(template)
    within("#template_preview") do
      assert_text "Sherpa family business"
      assert_text "Would you be open to a short call?"
      assert_no_text "prices"
      assert_no_text "packages"
    end
    capture("upgraded-first-reply-editor")
    visit edit_template_path(custom)
    assert_field "Subject", with: "My welcome"
    assert_field "Body", with: "Hi {{first_name}}, my own welcome."
    capture("preserved-captain-template")
  end

  test "manual interest and mirrored booking override website trip for the intended recipient" do
    seed_first_reply
    @lead.update!(trip_title: "Website trek", trip_interest: "Private Nepal tour")
    visit lead_path(@lead)
    insert_first_reply
    assert_first_reply("Private Nepal tour")
    PerfectBook::Contact.create!(perfectbook_id: 9981, name: @lead.name, email: @lead.email, synced_at: Time.current)
    @lead.update!(perfectbook_contact_id: 9981)
    PerfectBook::Booking.create!(perfectbook_id: 9982, perfectbook_contact_id: 9981,
      trip_name: "Booked Nepal trek", synced_at: Time.current)
    visit lead_path(@lead, new_thread: 1)
    insert_first_reply
    assert_first_reply("Booked Nepal trek")
    capture("booking-trip-precedence")
  end

  private

  def seed_first_reply
    Object.send(:remove_const, :TEMPLATES) if Object.const_defined?(:TEMPLATES)
    load Rails.root.join("db/seeds/templates.rb")
    Setting.current.update!(sender_name: "Sam")
  end

  def insert_first_reply
    open_details
    fill_in "Message", with: ""
    click_button "First reply to a new inquiry", match: :first
  end

  def assert_first_reply(trip)
    assert_field "Subject", with: "Planning your #{trip}"
    body = find_field("Message").value
    assert_includes body, "Hi Tashi,"
    assert_includes body, "help you plan your #{trip}"
    assert_includes body, "Sherpa family business"
    assert_includes body, "March 2026"
    assert_includes body, "Would you be open to a short call?"
    assert_includes body, "After we talk"
    assert_no_match(/\[missing:|Not sure yet|\$|prices|packages/i, body)
  end


  def open_details
    details = find(".reply-details")
    details.find("summary").click unless details["open"] == "true"
  end

  def capture(name)
    return unless ENV["OUTBOUND_EVIDENCE_DIR"].present?
    page.current_window.resize_to(1400, 1800) if name.include?("group")
    page.save_screenshot(File.join(ENV.fetch("OUTBOUND_EVIDENCE_DIR"), "#{name}.png"))
    page.current_window.resize_to(1400, 1000) if name.include?("group")
  end
end
