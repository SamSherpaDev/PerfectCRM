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
      assert_select "a[href=?]", TripQuizEmail::SAMPLE_QUIZ["share_url"], count: 0
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
      assert_select "dd", text: "Two to three weeks"
      assert_select "dd", text: "Spring (March to May)"
      assert_select "dd", text: "4"
      assert_select "dd", text: "Email their match and a free call"
      assert_select "dd", text: "No, box left unticked"
      assert_select "dt", text: "Came from", count: 0
      assert_select "dd", text: "Website", count: 0
    end
    assert_not_includes response.body, "Open theirs"
    assert_not_includes response.body, "Quiz version"
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
    assert_select "nav.tabbar a.on", text: "Settings"
    assert_select "a.nav-link-active[title=?]", "Settings"
    assert_select ".badge", text: "Off"
    assert_select "dd", text: "Your trip match"
    assert_select ".email-paper", count: 2
    assert_select "p", text: /When this email is queued, the automatic first reply stands aside/
    assert_full_and_closest_previews(/Sam or Gyalgin will call you as soon as possible\./)

    get settings_trip_quiz_email_path(call: 0)
    assert_select "a.tab-on", text: "Email only"
    assert_select ".email-paper", count: 2
    assert_full_and_closest_previews(/Reply to this email with your phone number and we will call you as soon as possible\./)
  end

  def assert_full_and_closest_previews(closing)
    assert_select "h2", text: "When the match meets every answer"
    assert_select "h2", text: "When the match is the closest, not a full fit"
    assert_select "#trip-quiz-email-preview-full", text: /Hi Alex,/
    assert_select "#trip-quiz-email-preview-full", text: /Your match: 15-Day Nepal Cultural and Wildlife Tour/
    assert_select "#trip-quiz-email-preview-full", text: /Two to three weeks: 15 days/
    assert_select "#trip-quiz-email-preview-full", text: /Where it differs/, count: 0
    assert_select "#trip-quiz-email-preview-closest", text: /The closest of our 35 trips to your answers: 15-Day Nepal Cultural and Wildlife Tour/
    assert_select "#trip-quiz-email-preview-closest", text: /Where it differs from your answers:\s*- Under two weeks: 15 days/
    [ "full", "closest" ].each do |kind|
      assert_select "#trip-quiz-email-preview-#{kind}", text: /Temples and old cities: Includes the Kathmandu Valley/
      assert_select "#trip-quiz-email-preview-#{kind}", text: /Also close:/
      assert_select "#trip-quiz-email-preview-#{kind}", text: closing
      assert_select "#trip-quiz-email-preview-#{kind}", text: /SherpaHolidays/
    end
    assert_not_includes response.body, "two call times"
    assert_not_includes response.body, "—"
  end
end
