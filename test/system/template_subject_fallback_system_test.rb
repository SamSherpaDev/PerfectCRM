require "application_system_test_case"
require_relative "../support/google_sign_in_test_helper"

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
    @lead.update!(perfectbook_contact_id: 7301)
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
      assert_field "Subject", with: "Documents for Nepal trip"
      assert_includes find_field("Message").value, "Tashi: visa"
      capture("documents-#{with_template}")
      click_link "Open in reply box"
      open_details
      assert_field "Subject", with: "Documents for Nepal trip"
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

  private

  def open_details
    details = find(".reply-details")
    details.find("summary").click unless details["open"] == "true"
  end

  def capture(name)
    return unless ENV["OUTBOUND_EVIDENCE_DIR"].present?
    page.save_screenshot(File.join(ENV.fetch("OUTBOUND_EVIDENCE_DIR"), "#{name}.png"))
  end
end
