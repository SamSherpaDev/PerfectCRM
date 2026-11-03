require "test_helper"

class LeadsTripQuizTest < ActiveSupport::TestCase
  def payload(overrides = {})
    {
      "quiz" => {
        "interests" => [ "temples", "jungle-safari", "lumbini" ],
        "pace" => "easy",
        "length" => "under-14",
        "season" => "spring",
        "group_size" => 4,
        "match" => {
          "handle" => "nepal-cultural-wildlife-tour",
          "title" => "15-Day Nepal Cultural and Wildlife Tour"
        },
        "alternates" => [
          {
            "handle" => "nepal-luxury-tour-kathmandu-chitwan-pokhara",
            "title" => "13-Day Nepal Premium Tour: Kathmandu, Chitwan & Pokhara"
          },
          {
            "handle" => "nepal-highlights-premium-tour",
            "title" => "9-Day Nepal Highlights Premium Tour"
          }
        ],
        "intent" => "email",
        "share_url" => "https://www.sherpaholidays.com/pages/find-your-perfect-trip#k=temples,jungle-safari,lumbini&p=easy&l=under-14&s=spring&n=4",
        "email_list" => false,
        "source" => "website"
      }.merge(overrides),
      "client" => { "version" => "trip-quiz-1" }
    }
  end

  def error_for(overrides)
    error = assert_raises(ArgumentError) { Leads::TripQuiz.parse(payload(overrides)) }
    error.message
  end

  test "keeps only the whitelisted quiz fields" do
    result = Leads::TripQuiz.parse(payload("passport_number" => "X123", "price" => 1200, "date_of_birth" => "1990-01-01"))
    assert_equal %w[match alternates interests pace length season group_size intent email_list share_url source].sort,
      result.keys.sort
    assert_equal({ "handle" => "nepal-cultural-wildlife-tour", "title" => "15-Day Nepal Cultural and Wildlife Tour" }, result["match"])
    assert_equal 2, result["alternates"].size
    assert_not_includes result.to_json, "trip-quiz-1"
    assert_not_includes result.to_json, "X123"
  end

  test "no quiz key means no quiz" do
    assert_nil Leads::TripQuiz.parse({ "message" => "Plain text quiz" })
  end

  test "non-hash quiz raises quiz" do
    error = assert_raises(ArgumentError) { Leads::TripQuiz.parse({ "quiz" => "not-a-hash" }) }
    assert_equal "quiz", error.message
  end

  test "trip titles keep a plain dash instead of en or em dashes" do
    result = Leads::TripQuiz.parse(payload("match" => { "handle" => "pokhara-mountain-views-tour", "title" => "Kathmandu — Patan – Pokhara" }))
    assert_equal "Kathmandu - Patan - Pokhara", result.dig("match", "title")
  end

  {
    "quiz.match" => { "match" => nil },
    "quiz.match.handle" => { "match" => { "handle" => "../etc", "title" => "Nepal Tour" } },
    "quiz.match.title" => { "match" => { "handle" => "nepal-tour", "title" => "Visit www.cheap-trips.com" } },
    "quiz.alternates" => { "alternates" => [
      { "handle" => "trip-1", "title" => "Trip 1" },
      { "handle" => "trip-2", "title" => "Trip 2" },
      { "handle" => "trip-3", "title" => "Trip 3" }
    ] },
    "quiz.alternates.handle" => { "alternates" => [ { "handle" => " bad_handle", "title" => "Trip 1" } ] },
    "quiz.alternates.title" => { "alternates" => [ { "handle" => "trip-1", "title" => "Only $999" } ] },
    "quiz.interests" => { "interests" => [ "everest", "everest" ] },
    "quiz.pace" => { "pace" => "sprint" },
    "quiz.length" => { "length" => "10-days" },
    "quiz.season" => { "season" => "monsoon" },
    "quiz.group_size" => { "group_size" => 21 },
    "quiz.intent" => { "intent" => "sms" },
    "quiz.email_list" => { "email_list" => "yes" },
    "quiz.source" => { "source" => "Instagram Bio!" },
    "quiz.share_url" => { "share_url" => "http://www.sherpaholidays.com/pages/find-your-perfect-trip" }
  }.each do |field, overrides|
    test "rejects a bad #{field}" do
      assert_equal field, error_for(overrides)
    end
  end

  test "interests accept 1 to 3 unique whitelisted codes" do
    Leads::TripQuiz::INTERESTS.keys.each_slice(3) do |codes|
      result = Leads::TripQuiz.parse(payload("interests" => codes))
      assert_equal codes, result["interests"]
    end
    [
      [],
      %w[everest temples mountain-views jungle-safari],
      %w[everest everest],
      %w[unknown],
      [ "Everest up close" ],
      "everest"
    ].each do |bad|
      assert_equal "quiz.interests", error_for("interests" => bad), bad.inspect
    end
  end

  test "handles and titles enforce format, length and text safety" do
    assert_equal "quiz.match.handle", error_for("match" => { "handle" => "with_underscore", "title" => "Tour" })
    assert_equal "quiz.match.handle", error_for("match" => { "handle" => "-starts-with-dash", "title" => "Tour" })
    assert_equal "quiz.match.handle", error_for("match" => { "handle" => "a" * 101, "title" => "Tour" })
    assert_equal "quiz.match.title", error_for("match" => { "handle" => "nepal-tour", "title" => "A" * 201 })

    [ "Email me at a@b.co", "<b>Pokhara</b>", "Only $999", "Pokhara 1200 USD", "https://evil.example", "Book now at evil.io" ].each do |title|
      assert_equal "quiz.match.title", error_for("match" => { "handle" => "pokhara", "title" => title }), title
      assert_equal "quiz.alternates.title", error_for("alternates" => [ { "handle" => "pokhara", "title" => title } ]), title
    end
  end

  test "share links stay on our own https page without credentials, port or query" do
    result = Leads::TripQuiz.parse(payload("share_url" => "https://SherpaHolidays.com/pages/contact?view=trip-quiz-preview#k=temples&p=easy"))
    assert_equal "https://sherpaholidays.com/pages/contact#k=temples&p=easy", result["share_url"]
    [
      "https://evil.example/pages/find-your-perfect-trip",
      "https://user:pass@www.sherpaholidays.com/pages/find-your-perfect-trip",
      "https://www.sherpaholidays.com:8443/pages/find-your-perfect-trip",
      "https://www.sherpaholidays.com/pages/find-your-perfect-trip#<script>",
      "javascript:alert(1)"
    ].each do |url|
      assert_equal "quiz.share_url", error_for("share_url" => url), url
    end
  end

  test "the same match and answers have the same signature and changed answers do not" do
    first = Leads::TripQuiz.parse(payload)
    reordered = Leads::TripQuiz.parse(payload("interests" => [ "lumbini", "temples", "jungle-safari" ]))
    changed_season = Leads::TripQuiz.parse(payload("season" => "fall"))
    changed_match = Leads::TripQuiz.parse(payload("match" => { "handle" => "nepal-highlights-premium-tour", "title" => "9-Day Nepal Highlights Premium Tour" }))
    assert_equal Leads::TripQuiz.signature(first), Leads::TripQuiz.signature(reordered)
    assert_not_equal Leads::TripQuiz.signature(first), Leads::TripQuiz.signature(changed_season)
    assert_not_equal Leads::TripQuiz.signature(first), Leads::TripQuiz.signature(changed_match)
  end

  test "answer_fit lists every answer the match meets as a fit and nothing else" do
    quiz = Leads::TripQuiz.parse(payload("length" => "14-20"))
    assert_equal({
      fits: [
        "Temples and old cities: Includes the Kathmandu Valley",
        "Jungle safari in Chitwan: Includes Chitwan and a wildlife safari",
        "Birthplace of the Buddha: Includes Lumbini",
        "Easy days: Rated Easy",
        "Two to three weeks: 15 days",
        "Spring: Best season Spring & Autumn",
        "4 travelers: Every journey is private"
      ],
      misses: []
    }, Leads::TripQuiz.answer_fit(quiz))
  end

  test "answer_fit keeps missed interests, pace, length and season out of the fits" do
    quiz = Leads::TripQuiz.parse(payload(
      "interests" => [ "everest", "temples" ],
      "pace" => "easy",
      "length" => "under-14",
      "season" => "summer",
      "group_size" => 1,
      "match" => { "handle" => "everest-base-camp-premium-trek", "title" => "18-Day Everest Base Camp Premium Trek" }
    ))
    assert_equal({
      fits: [
        "Everest up close: Includes the Everest region",
        "1 traveler: Every journey is private"
      ],
      misses: [
        "Temples and old cities: Not on this trip",
        "Easy days: Rated Challenging, two steps harder",
        "Under two weeks: 18 days",
        "Summer: Best season Spring & Autumn"
      ]
    }, Leads::TripQuiz.answer_fit(quiz))
  end

  test "answer_fit reads a season range and not-sure answers as fits" do
    tibet = Leads::TripQuiz.parse(payload(
      "interests" => [ "beyond" ], "pace" => "moderate", "length" => "not_sure", "season" => "summer",
      "match" => { "handle" => "tibet-overland-tour-lhasa", "title" => "8-Day Tibet Overland Tour" }
    ))
    assert_equal [], Leads::TripQuiz.answer_fit(tibet)[:misses]
    assert_includes Leads::TripQuiz.answer_fit(tibet)[:fits], "Length: 8 days"
    assert_includes Leads::TripQuiz.answer_fit(tibet)[:fits], "Summer: Best season Spring to Autumn"

    winter = Leads::TripQuiz.parse(payload("season" => "winter",
      "match" => { "handle" => "india-nepal-premium-tour", "title" => "13-Day India and Nepal Premium Tour" }))
    assert_includes Leads::TripQuiz.answer_fit(winter)[:fits], "Winter: Best season Autumn to Spring"
    assert_includes Leads::TripQuiz.answer_fit(Leads::TripQuiz.parse(payload("season" => "not_sure")))[:fits],
      "When: Best season Spring & Autumn"
  end
end
