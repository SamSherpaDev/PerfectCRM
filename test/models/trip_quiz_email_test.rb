require "test_helper"

class TripQuizEmailTest < ActiveSupport::TestCase
  setup do
    Setting.current.update!(trip_quiz_email_enabled: true)
    Setting.current.update_columns(trip_quiz_email_enabled_at: 1.hour.ago)
    @lead = Lead.create!(name: "Anna Lindqvist", email: "anna@gmail.com", capture_channel: "website_form",
      external_ref: "website_form:#{SecureRandom.uuid}", placement: "trip_quiz",
      metadata: { "quiz" => TripQuizEmail::SAMPLE_QUIZ })
  end

  def reason
    TripQuizEmail.skip_reason(@lead.reload, email: @lead.email)
  end

  test "a fresh quiz inquiry is eligible, existing client or not" do
    assert_nil reason
    Client.create!(name: "Anna Lindqvist", email: "anna@gmail.com")
    assert_nil reason
  end

  {
    "setting is off" => ->(lead) { Setting.current.update!(trip_quiz_email_enabled: false) },
    "old inquiry" => ->(lead) { lead.update_columns(created_at: 2.hours.ago) },
    "no quiz" => ->(lead) { lead.update_columns(metadata: {}) },
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
    Setting.current.update!(trip_quiz_email_enabled: false)
    Setting.current.update!(trip_quiz_email_enabled: true)
    assert_operator Setting.current.trip_quiz_email_enabled_at, :>=, @lead.created_at
    assert_equal "old inquiry", reason
  end

  test "one address gets at most three trip quiz emails a day" do
    3.times { TripQuizEmail.create!(email: "anna@gmail.com") }
    assert_equal "daily limit for this address", reason
  end

  test "a full match names the match, every answer under why it fits, alternates and the call offer, without prices or em dashes" do
    content = TripQuizEmail.content(first_name: "Anna", quiz: TripQuizEmail::SAMPLE_QUIZ)
    body = content[:body]
    assert_equal "Your trip match", content[:subject]
    assert body.start_with?("Hi Anna,\n\nThank you for taking our trip quiz at SherpaHolidays.")
    assert_includes body, "Your match: 15-Day Nepal Cultural and Wildlife Tour\nhttps://www.sherpaholidays.com/products/nepal-cultural-wildlife-tour"
    assert_includes body, "Why it fits:\n" \
      "- Temples and old cities: Includes the Kathmandu Valley\n" \
      "- Jungle safari in Chitwan: Includes Chitwan and a wildlife safari\n" \
      "- Birthplace of the Buddha: Includes Lumbini\n" \
      "- Easy days: Rated Easy\n" \
      "- Two to three weeks: 15 days\n" \
      "- Spring: Best season Spring & Autumn\n" \
      "- 4 travelers: Every journey is private\n\nAlso close:"
    assert_not_includes body, "Where it differs"
    assert_not_includes body, "The closest of our"
    assert_includes body, "Also close:\n- 13-Day Nepal Premium Tour: Kathmandu, Chitwan & Pokhara\n  https://www.sherpaholidays.com/products/nepal-luxury-tour-kathmandu-chitwan-pokhara\n- 9-Day Nepal Highlights Premium Tour\n  https://www.sherpaholidays.com/products/nepal-highlights-premium-tour"
    assert_includes body, "Would a free call help? Sam or Gyalgin can go over this trip, the season and the pace with you. No obligation. Reply to this email with your phone number and we will call you as soon as possible."
    assert_not_includes body, "—"
    assert_not_includes body, "two call times"
    assert_no_match(/[$€£]|\bUSD\b|price/i, body)
    assert_no_match(/Sherpa Holidays/, body)
  end

  test "a closest match keeps missed answers out of why it fits and lists them in their own section" do
    body = TripQuizEmail.content(first_name: "Anna", quiz: TripQuizEmail::SAMPLE_CLOSEST_QUIZ)[:body]
    assert_includes body, "The closest of our 35 trips to your answers: 15-Day Nepal Cultural and Wildlife Tour\n" \
      "https://www.sherpaholidays.com/products/nepal-cultural-wildlife-tour"
    assert_not_includes body, "Your match:"
    assert_includes body, "- Spring: Best season Spring & Autumn\n- 4 travelers: Every journey is private\n\n" \
      "Where it differs from your answers:\n- Under two weeks: 15 days\n\nAlso close:"
    assert_equal 1, body.scan("Under two weeks").size

    harder = TripQuizEmail.content(first_name: "Anna", quiz: TripQuizEmail::SAMPLE_QUIZ.merge(
      "interests" => [ "temples" ], "match" => { "handle" => "everest-base-camp-premium-trek", "title" => "18-Day Everest Base Camp Premium Trek" }
    ))[:body]
    why, differs = harder.split("Where it differs from your answers:\n")
    assert_includes differs, "- Temples and old cities: Not on this trip\n- Easy days: Rated Challenging, two steps harder"
    assert_not_includes why, "Not on this trip"
    assert_not_includes why, "harder"
  end

  test "a call request turns the offer into a call-as-soon-as-possible confirmation without mentioning a window or two call times" do
    [
      { call_request: TripQuizEmail::SAMPLE_CALL_REQUEST, quiz: TripQuizEmail::SAMPLE_QUIZ },
      { call_request: { "window" => "weekday_morning", "timezone" => "America/New_York" }, quiz: TripQuizEmail::SAMPLE_QUIZ },
      { call_request: nil, quiz: TripQuizEmail::SAMPLE_QUIZ.merge("intent" => "call") }
    ].each do |attrs|
      body = TripQuizEmail.content(first_name: "Anna", quiz: attrs[:quiz], call_request: attrs[:call_request])[:body]
      assert body.end_with?("Thank you for asking for a free call. Sam or Gyalgin will call you as soon as possible.")
      assert_not_includes body, "two call times"
      assert_not_includes body, "weekday"
    end
  end

  test "an odd first name falls back to a plain greeting" do
    [ "anna@gmail.com", "Visit evil.io", "R2D2", "" ].each do |name|
      body = TripQuizEmail.content(first_name: name, quiz: TripQuizEmail::SAMPLE_QUIZ)[:body]
      assert body.start_with?("Hello,\n\n"), name
    end
  end
end
