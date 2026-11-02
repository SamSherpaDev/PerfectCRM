require "test_helper"

class ItineraryEmailTest < ActiveSupport::TestCase
  setup do
    Setting.current.update!(itinerary_email_enabled: true)
    Setting.current.update_columns(itinerary_email_enabled_at: 1.hour.ago)
    @lead = Lead.create!(name: "Anna Lindqvist", email: "anna@gmail.com", capture_channel: "website_form",
      external_ref: "website_form:#{SecureRandom.uuid}", placement: "itinerary_designer",
      metadata: { "itinerary" => ItineraryEmail::SAMPLE_ITINERARY })
  end

  def reason
    ItineraryEmail.skip_reason(@lead.reload, email: @lead.email)
  end

  test "a fresh designer inquiry is eligible, existing client or not" do
    assert_nil reason
    Client.create!(name: "Anna Lindqvist", email: "anna@gmail.com")
    assert_nil reason
  end

  {
    "setting is off" => ->(lead) { Setting.current.update!(itinerary_email_enabled: false) },
    "old inquiry" => ->(lead) { lead.update_columns(created_at: 2.hours.ago) },
    "no itinerary" => ->(lead) { lead.update_columns(metadata: {}) },
    "not a website inquiry" => ->(lead) { lead.update!(capture_channel: "email") },
    "invalid email" => ->(lead) { lead.update_columns(email: "bad-address") },
    "our own domain" => ->(lead) { lead.update!(email: "team@sherpaholidays.com") },
    "test address" => ->(lead) { lead.update!(email: "visitor@example.org") },
    "spam or junk" => ->(lead) { lead.update!(spam_score: 10) },
    "not interested" => ->(lead) { lead.update!(not_interested_marked_at: Time.current) },
    "inactive inquiry" => ->(lead) { lead.update!(archived_at: Time.current) }
  }.each do |expected, prepare|
    test "skips #{expected}" do
      prepare.call(@lead)
      assert_equal expected, reason
    end
  end

  test "switching it on again only covers inquiries after that moment" do
    Setting.current.update!(itinerary_email_enabled: false)
    Setting.current.update!(itinerary_email_enabled: true)
    assert_operator Setting.current.itinerary_email_enabled_at, :>=, @lead.created_at
    assert_equal "old inquiry", reason
  end

  test "one address gets at most three itinerary emails a day" do
    3.times { ItineraryEmail.create!(email: "anna@gmail.com") }
    assert_equal "daily limit for this address", reason
  end

  test "the email is the itinerary, the link back and the call offer, without prices or em dashes" do
    content = ItineraryEmail.content(first_name: "Anna", itinerary: ItineraryEmail::SAMPLE_ITINERARY)
    body = content[:body]
    assert_equal "Your Nepal itinerary", content[:subject]
    assert body.start_with?("Hi Anna,\n\nThank you for designing your trip with SherpaHolidays.")
    assert_includes body, "Starting from: Pokhara Mountain Views Tour"
    assert_includes body, "Length: About 1 week"
    assert_includes body, "Pace: Easy days"
    assert_includes body, "When: Fall (October to December)"
    assert_includes body, "Travelers: 2"
    assert_includes body, "Day 1: Kathmandu\nDays 2-3: Pokhara and Sarangkot"
    assert_includes body, "See or change your itinerary:\n#{ItineraryEmail::SAMPLE_ITINERARY['share_url']}"
    assert_includes body, "Would a free call help? Sam or Gyalgin"
    assert_not_includes body, "—"
    assert_no_match(/[$€£]|\bUSD\b|price/i, body)
    assert_no_match(/Sherpa Holidays/, body)
  end

  test "a call request turns the offer into a confirmation" do
    body = ItineraryEmail.content(first_name: "Anna", itinerary: ItineraryEmail::SAMPLE_ITINERARY,
      call_request: ItineraryEmail::SAMPLE_CALL_REQUEST)[:body]
    assert body.end_with?("Thank you for asking for a free call. Sam or Gyalgin will email you two call times on weekday mornings, your time.")
  end

  test "an odd first name falls back to a plain greeting" do
    [ "anna@gmail.com", "Visit evil.io", "R2D2", "" ].each do |name|
      body = ItineraryEmail.content(first_name: name, itinerary: ItineraryEmail::SAMPLE_ITINERARY)[:body]
      assert body.start_with?("Hello,\n\n"), name
    end
  end
end
