require "test_helper"
require_relative "../support/google_sign_in_test_helper"

# The trip quiz's signed-in pages: the Quiz answers card on the lead page and
# the trip quiz email preview in Settings.
class TripQuizPagesTest < ActionDispatch::IntegrationTest
  include GoogleSignInTestHelper

  def quiz_lead(name: "Anna Lindqvist", email: "anna@gmail.com", quiz: TripQuizEmail::SAMPLE_QUIZ, metadata: {}, **attributes)
    Lead.create!(name: name, email: email, source: "website_form", capture_channel: "website_form",
      external_ref: "website_form:#{SecureRandom.uuid}", placement: "trip_quiz",
      received_at: Time.current, metadata: { "quiz" => quiz }.merge(metadata), **attributes)
  end

  test "preview page needs sign in" do
    get settings_trip_quiz_email_path
    assert_redirected_to sign_in_path
  end

  test "the lead page shows the quiz answers card with linked match, alternates, answers, intent and trip notes" do
    sign_in
    lead = quiz_lead(metadata: {
      "call_request" => { "timezone" => "America/New_York", "requested_at" => Time.current.iso8601 }
    })
    get lead_path(lead)
    assert_response :success
    assert_select "#record-quiz" do
      assert_select "h2", "Quiz answers"
      assert_select "a[href=?][target=_blank]", TripQuizEmail::SAMPLE_QUIZ["share_url"], text: /Open theirs/
      assert_select "a[href=?][target=_blank]", "https://www.sherpaholidays.com/products/nepal-cultural-wildlife-tour",
        text: "15-Day Nepal Cultural and Wildlife Tour"
      assert_select "a[href=?][target=_blank]", "https://www.sherpaholidays.com/products/nepal-luxury-tour-kathmandu-chitwan-pokhara",
        text: "13-Day Nepal Premium Tour: Kathmandu, Chitwan & Pokhara"
      assert_select "a[href=?][target=_blank]", "https://www.sherpaholidays.com/products/nepal-highlights-premium-tour",
        text: "9-Day Nepal Highlights Premium Tour"
      assert_select ".chip", text: "Temples and old cities"
      assert_select ".chip", text: "Jungle safari in Chitwan"
      assert_select ".chip", text: "Birthplace of the Buddha"
      assert_select "dd", text: "Easy days"
      assert_select "dd", text: "Under two weeks"
      assert_select "dd", text: "Spring (March to May)"
      assert_select "dd", text: "4"
      assert_select "dd", text: "Email their match and a free call"
      assert_select "dd", text: "No, box left unticked"
      assert_select "dd", text: "Website"
      assert_select ".mono", text: "trip-quiz-1"
    end
    assert_select "#record-details dd", text: /As soon as possible \(America\/New York\)/
    assert_select "#record-details dd", text: /Call them as soon as possible\./
    assert_not_includes response.body, "two call times"
    assert_not_includes response.body, "—"
  end

  test "the lead page keeps accepting an old-style call time window on a quiz lead" do
    sign_in
    lead = quiz_lead(metadata: {
      "call_request" => { "window" => "weekday_morning", "timezone" => "America/New_York", "requested_at" => Time.current.iso8601 }
    })
    get lead_path(lead)
    assert_response :success
    assert_select "#record-details dd", text: /Weekday mornings, their time \(America\/New York\)/
    assert_select "#record-details dd", text: /Call them as soon as possible\./
  end

  test "leads without a quiz do not show the quiz answers card" do
    sign_in
    lead = Lead.create!(name: "Plain Inquiry", email: "plain@gmail.com", source: "website_form", placement: "landing")
    get lead_path(lead)
    assert_response :success
    assert_select "#record-quiz", count: 0
  end

  test "the preview shows both variants of the trip quiz email without em dashes" do
    sign_in
    Setting.current.update!(sender_name: "Sam", email_signature: "Sam\nSherpaHolidays")
    get settings_trip_quiz_email_path
    assert_response :success
    assert_select "h1", "Trip quiz email"
    assert_select ".badge", text: "Off"
    assert_select "dd", text: "Your trip match"
    assert_select ".email-paper", text: /Hi Alex,/
    assert_select ".email-paper", text: /Your match: 15-Day Nepal Cultural and Wildlife Tour/
    assert_select ".email-paper", text: /Temples and old cities: Includes the Kathmandu Valley/
    assert_select ".email-paper", text: /Also close:/
    assert_select ".email-paper", text: /Sam or Gyalgin will call you as soon as possible\./
    assert_select ".email-paper", text: /SherpaHolidays/
    assert_select "p", text: /The automatic first reply always skips trip quiz visitors/
    assert_not_includes response.body, "two call times"
    assert_not_includes response.body, "—"

    get settings_trip_quiz_email_path(call: 0)
    assert_select ".email-paper", text: /Would a free call help\?/
    assert_select ".email-paper", text: /Reply to this email with your phone number and we will call you as soon as possible\./
    assert_select "a.tab-on", text: "Email only"
    assert_not_includes response.body, "two call times"
    assert_not_includes response.body, "—"
  end
end
