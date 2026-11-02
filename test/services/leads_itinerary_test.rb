require "test_helper"

class LeadsItineraryTest < ActiveSupport::TestCase
  def payload(overrides = {})
    {
      "itinerary" => {
        "base_trip" => { "handle" => "pokhara-mountain-views-tour", "title" => "Pokhara Mountain Views Tour" },
        "stops" => [
          { "title" => "Kathmandu", "day_from" => 1, "code" => "ktm1" },
          { "title" => "Pokhara and Sarangkot", "day_from" => 2, "day_to" => 3, "code" => "sara",
            "from_trip" => { "handle" => "pokhara-mountain-views-tour", "title" => "Pokhara Mountain Views Tour" } }
        ],
        "interests" => [ "Mountain views, easy walking", "Temples and old cities" ],
        "pace" => "easy",
        "length_days" => 7,
        "season" => "fall",
        "group_size" => 2,
        "email_list" => false,
        "share_url" => "https://www.sherpaholidays.com/pages/design-your-trip#p=easy&s=ktm1,sara&n=2&w=fall",
        "source" => "instagram_bio"
      }.merge(overrides),
      "client" => { "version" => "itinerary-designer@1.0.0" }
    }
  end

  def error_for(overrides)
    error = assert_raises(ArgumentError) { Leads::Itinerary.parse(payload(overrides)) }
    error.message
  end

  test "keeps only the whitelisted itinerary fields" do
    result = Leads::Itinerary.parse(payload("passport_number" => "X123", "price" => 1200, "date_of_birth" => "1990-01-01"))
    assert_equal %w[version base_trip stops interests pace length_days season group_size email_list share_url source client_version].sort,
      result.keys.sort
    assert_equal 1, result["version"]
    assert_equal({ "title" => "Kathmandu", "day_from" => 1, "day_to" => 1, "code" => "ktm1" }, result["stops"].first)
    assert_equal "pokhara-mountain-views-tour", result["stops"].last.dig("from_trip", "handle")
    assert_equal "itinerary-designer@1.0.0", result["client_version"]
    assert_not_includes result.to_json, "X123"
  end

  test "no itinerary key means no itinerary" do
    assert_nil Leads::Itinerary.parse({ "message" => "Plain text itinerary" })
  end

  test "trip titles keep a plain dash instead of en or em dashes" do
    result = Leads::Itinerary.parse(payload("stops" => [ { "title" => "Kathmandu — Patan – Bhaktapur", "day_from" => 1 } ]))
    assert_equal "Kathmandu - Patan - Bhaktapur", result["stops"].first["title"]
  end

  {
    "itinerary.stops" => { "stops" => [] },
    "itinerary.stops.day_from" => { "stops" => [ { "title" => "Kathmandu", "day_from" => 0 } ] },
    "itinerary.stops.day_to" => { "stops" => [ { "title" => "Kathmandu", "day_from" => 3, "day_to" => 2 } ] },
    "itinerary.stops.title" => { "stops" => [ { "title" => "Visit www.cheap-trips.com", "day_from" => 1 } ] },
    "itinerary.pace" => { "pace" => "sprint" },
    "itinerary.season" => { "season" => "summer" },
    "itinerary.length_days" => { "length_days" => "7" },
    "itinerary.interests" => { "interests" => [ "Cheap flights to Kathmandu" ] },
    "itinerary.group_size" => { "group_size" => 21 },
    "itinerary.email_list" => { "email_list" => "yes" },
    "itinerary.source" => { "source" => "Instagram Bio!" },
    "itinerary.base_trip.handle" => { "base_trip" => { "handle" => "../etc" } },
    "itinerary.share_url" => { "share_url" => "http://www.sherpaholidays.com/pages/design-your-trip" }
  }.each do |field, overrides|
    test "rejects a bad #{field}" do
      assert_equal field, error_for(overrides)
    end
  end

  test "rejects text with links, addresses, markup or prices" do
    [ "Email me at a@b.co", "<b>Pokhara</b>", "Only $999", "Pokhara 1200 USD", "https://evil.example", "Book now at evil.io" ].each do |title|
      assert_equal "itinerary.stops.title", error_for("stops" => [ { "title" => title, "day_from" => 1 } ]), title
      assert_equal "itinerary.base_trip.title", error_for("base_trip" => { "handle" => "pokhara", "title" => title }), title
    end
  end

  test "interests and length take only the designer's fixed choices" do
    result = Leads::Itinerary.parse(payload("interests" => Leads::Itinerary::INTERESTS + [ "Everest up close" ], "length_days" => 21))
    assert_equal Leads::Itinerary::INTERESTS, result["interests"]
    assert_equal 21, result["length_days"]
    [ [ "Everest up close " ], [ "everest up close" ], [ 7 ], "Everest up close" ].each do |interests|
      assert_equal "itinerary.interests", error_for("interests" => interests), interests.inspect
    end
    [ 10, 7.0, 0, 28 ].each do |days|
      assert_equal "itinerary.length_days", error_for("length_days" => days), days.inspect
    end
  end

  test "share links stay on our own https page without credentials, port or query" do
    result = Leads::Itinerary.parse(payload("share_url" => "https://SherpaHolidays.com/pages/design-your-trip?fbclid=abc#p=easy&s=ktm1"))
    assert_equal "https://sherpaholidays.com/pages/design-your-trip#p=easy&s=ktm1", result["share_url"]
    [
      "https://evil.example/pages/design-your-trip",
      "https://user:pass@www.sherpaholidays.com/pages/design-your-trip",
      "https://www.sherpaholidays.com:8443/pages/design-your-trip",
      "https://www.sherpaholidays.com/pages/design-your-trip#<script>",
      "javascript:alert(1)"
    ].each do |url|
      assert_equal "itinerary.share_url", error_for("share_url" => url), url
    end
  end

  test "call requests take a known window and a real time zone" do
    assert_equal({ "window" => "weekend" }, Leads::Itinerary.call_request({ "window" => "weekend" }))
    assert_equal({ "window" => "weekday_morning", "timezone" => "America/New_York" },
      Leads::Itinerary.call_request({ "window" => "weekday_morning", "timezone" => "America/New_York" }))
    assert_raises(ArgumentError, "call_request.window") { Leads::Itinerary.call_request({ "window" => "midnight" }) }
    error = assert_raises(ArgumentError) { Leads::Itinerary.call_request({ "window" => "weekend", "timezone" => "Mars/Olympus" }) }
    assert_equal "call_request.timezone", error.message
    assert_raises(ArgumentError) { Leads::Itinerary.call_request("weekend") }
  end

  test "the same trip has the same signature and a changed trip does not" do
    first = Leads::Itinerary.parse(payload)
    again = Leads::Itinerary.parse(payload("interests" => [ "Temples and old cities", "Mountain views, easy walking" ]))
    changed = Leads::Itinerary.parse(payload("length_days" => 14))
    assert_equal Leads::Itinerary.signature(first), Leads::Itinerary.signature(again)
    assert_not_equal Leads::Itinerary.signature(first), Leads::Itinerary.signature(changed)
  end

  test "labels read plainly" do
    assert_equal "Day 1", Leads::Itinerary.day_label({ "day_from" => 1, "day_to" => 1 })
    assert_equal "Days 2-3", Leads::Itinerary.day_label({ "day_from" => 2, "day_to" => 3 })
    assert_equal "about a week", Leads::Itinerary.length_label(7)
    assert_equal "about two weeks", Leads::Itinerary.length_label(14)
    assert_equal "about three weeks", Leads::Itinerary.length_label(21)
    assert_nil Leads::Itinerary.length_label(nil)
    assert_equal "Instagram bio", Leads::Itinerary.source_label("instagram_bio")
    assert_equal 3, Leads::Itinerary.planned_days(Leads::Itinerary.parse(payload))
  end
end
