require "test_helper"
require_relative "../support/google_sign_in_test_helper"

# The itinerary designer's signed-in pages: the lead card, the itinerary
# email preview, and the monthly "What people build" view.
class ItineraryPagesTest < ActionDispatch::IntegrationTest
  include GoogleSignInTestHelper

  def designer_lead(name: "Anna Lindqvist", email: "anna@gmail.com", itinerary: ItineraryEmail::SAMPLE_ITINERARY, metadata: {}, **attributes)
    Lead.create!(name: name, email: email, source: "website_form", capture_channel: "website_form",
      external_ref: "website_form:#{SecureRandom.uuid}", placement: "itinerary_designer",
      received_at: Time.current, metadata: { "itinerary" => itinerary }.merge(metadata), **attributes)
  end

  test "every page needs sign in" do
    [ settings_itinerary_email_path, itinerary_insights_path ].each do |path|
      get path
      assert_redirected_to sign_in_path
    end
  end

  test "the lead page shows the trip they built and the free call they asked for" do
    sign_in
    lead = designer_lead(metadata: {
      "call_request" => { "window" => "weekday_morning", "timezone" => "America/New_York", "requested_at" => Time.current.iso8601 }
    })
    get lead_path(lead)
    assert_response :success
    assert_select "#record-itinerary" do
      assert_select "h2", "Itinerary"
      assert_select "a[href=?][target=_blank]", ItineraryEmail::SAMPLE_ITINERARY["share_url"], text: /Open theirs/
      assert_select "dd", text: "Pokhara Mountain Views Tour"
      assert_select "dd", text: "About a week · 8 days planned"
      assert_select "dd", text: "Easy days"
      assert_select "dd", text: "Fall (October to December)"
      assert_select ".chip", text: "Temples and old cities"
      assert_select ".itinerary-days li", 5
      assert_select ".itinerary-day", text: "Days 2-3"
      assert_select "dd", text: "No, box left unticked"
      assert_select "dd", text: "Instagram bio"
      assert_select "a[href*=?]", settings_itinerary_email_path, count: 0
      assert_select "a[href=?]", itinerary_insights_path
      assert_select ".mono", text: "itinerary-designer@1.0.0"
    end
    assert_select "#record-details dd", text: /Weekday mornings, their time \(America\/New York\)/
    assert_not_includes response.body, "— Itinerary"
  end

  test "leads without an itinerary keep their page as before" do
    sign_in
    lead = Lead.create!(name: "Plain Inquiry", email: "plain@gmail.com", source: "website_form", placement: "landing")
    get lead_path(lead)
    assert_response :success
    assert_select "#record-itinerary", count: 0
  end

  test "the preview shows the sample email with and without a call request" do
    sign_in
    Setting.current.update!(sender_name: "Sam", email_signature: "Sam\nSherpaHolidays")
    get settings_itinerary_email_path
    assert_response :success
    assert_select "h1", "Itinerary email"
    assert_select ".badge", text: "Off"
    assert_select "dd", text: "Your Nepal itinerary"
    assert_select ".email-paper", text: /Hi Alex,/
    assert_select ".email-paper", text: /Days 2-3: Pokhara and Sarangkot/
    assert_select ".email-paper", text: /Sam or Gyalgin will email you two call times on weekday mornings, your time\./
    assert_select ".email-paper", text: /SherpaHolidays/
    assert_select "p", text: /the automatic first reply skips itinerary designer visitors/
    assert_not_includes response.body, "—"

    get settings_itinerary_email_path(call: 0)
    assert_select ".email-paper", text: /Would a free call help\?/
    assert_select "a.tab-on", text: "No call request yet"
  end

  test "what people build counts one month of designer inquiries without spam or tests" do
    sign_in
    travel_to Time.zone.local(2026, 11, 20, 10) do
      route = ->(*titles) { titles.each_with_index.map { |title, index| { "title" => title, "day_from" => index + 1, "day_to" => index + 1 } } }
      designer_lead(itinerary: ItineraryEmail::SAMPLE_ITINERARY.merge("stops" => route.call("Kathmandu", "Chitwan", "Pokhara"), "source" => "instagram_bio"))
      designer_lead(email: "bea@gmail.com", metadata: { "call_request" => { "window" => "weekend" } },
        itinerary: ItineraryEmail::SAMPLE_ITINERARY.except("source").merge(
          "stops" => route.call("Kathmandu", "Pokhara", "Chitwan", "Bandipur"), "length_days" => 14, "season" => "spring"
        ))
      designer_lead(email: "spam@gmail.com", spam_marked_at: Time.current)
      designer_lead(email: "test@gmail.com", is_test: true)
      designer_lead(email: "october@gmail.com", received_at: Time.zone.local(2026, 10, 31, 23))

      get itinerary_insights_path
      assert_response :success
      assert_select "h1", "What people build"
      assert_select ".stat-value", text: "2"
      assert_select "nav[aria-label=Month] span", text: "November 2026 (so far)"
      assert_select "#stops-heading + div tbody tr", 4
      assert_select "#stops-heading + div tbody tr:first-child td:first-child", text: "Chitwan"
      assert_select "#combinations-heading ~ div tbody tr", 3
      assert_select "#combinations-heading ~ div tbody tr:first-child td:first-child", text: "Chitwan + Kathmandu"
      assert_select "#combinations-heading ~ div tbody td", text: "Chitwan + Pokhara"
      assert_select "#combinations-heading ~ div tbody td", text: /Bandipur/, count: 0
      assert_select "#lengths-heading + div tbody td", text: "About two weeks"
      assert_select "#seasons-heading + div tbody tr", 4
      assert_select "#sources-heading ~ div tbody td", text: "Not given"
      assert_select "#sources-heading ~ div tbody td", text: "Instagram bio"

      get itinerary_insights_path(month: "2026-10")
      assert_select ".stat-value", text: "1"
      assert_select "a", text: "Next"
      get itinerary_insights_path(month: "2027-01")
      assert_select "nav[aria-label=Month] span", text: "November 2026 (so far)"
      get itinerary_insights_path(month: "2026-09")
      assert_select "p", text: "No itineraries in September"
    end
  end
end
