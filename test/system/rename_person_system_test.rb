require "application_system_test_case"
require_relative "../support/google_sign_in_test_helper"

class RenamePersonSystemTest < ApplicationSystemTestCase
  include GoogleSignInTestHelper

  test "renaming a lead, client, and person updates linked records, search, and timeline" do
    lead = Lead.create!(
      name: "Elena Rossi",
      email: "inquiry-101@example.com",
      phone: "+1-415-555-0101",
      source: "website_form"
    )
    lead.people.create!(name: "Elena Rossi", role: "Primary", email: "inquiry-101@example.com")
    task = Task.create!(subject: lead, title: "Follow up with Elena Rossi", due_on: Date.current)
    ScheduledCall.create!(lead: lead, scheduled_at: Time.current.change(hour: 15), notes: "Call Elena Rossi about dates")

    conv = Conversation.create!(subject: "Dolomites trek", linkable: lead, last_message_at: 1.hour.ago)
    Message.create!(
      conversation: conv,
      direction: "out",
      status: "sent",
      to_addrs: "Elena Rossi <inquiry-101@example.com>",
      subject: "Dolomites trek",
      text_body: "Hi Elena Rossi, here is the itinerary.",
      sent_at: 1.hour.ago
    )

    origin_lead = Lead.create!(
      name: "Tom Becker",
      email: "traveler-202@example.com",
      source: "referral"
    )
    origin_lead.people.create!(name: "Tom Becker", role: "Primary", email: "traveler-202@example.com")
    origin_lead.people.create!(name: "Lena Weber", role: "Partner", email: "partner-202@example.com")
    client = origin_lead.convert_to_client!

    browser_sign_in
    page.current_window.resize_to(1400, 900)

    # 1. Rename lead via Edit form
    visit lead_path(lead)
    assert_selector "h1", text: "Elena Rossi"
    click_link "Edit"
    assert_selector "h1", text: "Edit lead"

    fill_in "Display name", with: "Sofia Conti"
    click_button "Save"

    assert_selector "h1", text: "Sofia Conti"
    assert_text "Name changed from Elena Rossi to Sofia Conti"
    # Sent message stays historical
    assert_text "Hi Elena Rossi, here is the itinerary."
    within(".record-details") do
      assert_text "Sofia Conti"
      assert_no_text "Elena Rossi"
    end
    assert_equal "Follow up with Elena Rossi", task.reload.title
    assert_no_overflow("lead page desktop", 1400)

    # Today page shows updated lead name and the call note as written
    visit root_path
    assert_text "Sofia Conti"
    assert_text "Call Elena Rossi about dates"

    # Search finds new lead name and not old name
    visit leads_path(q: "Sofia Conti")
    assert_text "Sofia Conti"
    visit leads_path(q: "Elena Rossi")
    assert_no_text "Sofia Conti"

    # 2. Rename client and companion person via Edit form, then check at phone width
    visit client_path(client)
    assert_selector "h1", text: "Tom Becker"
    click_link "Edit"
    assert_selector "h1", text: "Edit client"

    fill_in "Display name", with: "Marcus Vance"
    person_fields = all("input[name*='[people_attributes]'][name$='[name]']")
    primary_field = person_fields.find { |el| el.value == "Tom Becker" }
    companion_field = person_fields.find { |el| el.value == "Lena Weber" }
    primary_field.fill_in(with: "Marcus Vance")
    companion_field.fill_in(with: "Clara Meyer")
    click_button "Save"

    assert_selector "h1", text: "Marcus Vance"
    assert_text "Name changed from Tom Becker to Marcus Vance"
    assert_text "Name changed from Lena Weber to Clara Meyer"
    within(".record-details") do
      assert_text "Marcus Vance"
      assert_text "Clara Meyer"
      assert_no_text "Tom Becker"
      assert_no_text "Lena Weber"
    end

    assert_equal "Marcus Vance", origin_lead.reload.name
    assert_equal [ "Clara Meyer", "Marcus Vance" ], origin_lead.people.reload.map(&:name).sort

    # Verify phone layout (390x844)
    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width: 390, height: 844, deviceScaleFactor: 2, mobile: true)
    visit client_path(client)
    assert_selector "h1", text: "Marcus Vance"
    assert_no_overflow("client page phone", 390)

    click_button "Details", exact: true
    assert_text "Clara Meyer"
    assert_no_overflow("client details tab phone", 390)

    # Search finds client by new companion name and not old name
    visit clients_path(q: "Clara Meyer")
    assert_text "Marcus Vance"
    visit clients_path(q: "Lena Weber")
    assert_no_text "Marcus Vance"
  ensure
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride") rescue nil
  end

  private

  def browser_sign_in
    OmniAuth.config.mock_auth[:google_oauth2] = OmniAuth::AuthHash.new(
      provider: "google_oauth2", uid: "google-captain",
      extra: { id_token: JWT.encode(@claims, @key, "RS256") }
    )
    Google::Auth::IDTokens.stub(:oidc_key_source, @source) do
      visit "/auth/google_oauth2/callback"
      assert_selector "h1", text: "Today"
    end
  end

  def assert_no_overflow(context, max_width)
    width = page.evaluate_script("document.documentElement.scrollWidth")
    assert_operator width, :<=, max_width, "#{context} overflows a #{max_width}px viewport (#{width}px)"
  end
end
