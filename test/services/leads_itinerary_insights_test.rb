require "test_helper"

class LeadsItineraryInsightsTest < ActiveSupport::TestCase
  def designer_lead(stops, **itinerary)
    Lead.create!(name: "Visitor", email: "visitor#{SecureRandom.hex(3)}@gmail.com", source: "website_form",
      placement: "itinerary_designer", received_at: Time.zone.local(2026, 11, 10, 9),
      metadata: { "itinerary" => { "stops" => stops.each_with_index.map { |title, index| { "title" => title, "day_from" => index + 1, "day_to" => index + 1 } } }.merge(itinerary) })
  end

  test "from five itineraries, stops in every one stay out of the combinations" do
    3.times { designer_lead([ "Kathmandu", "Chitwan", "Pokhara" ]) }
    designer_lead([ "Kathmandu", "Bandipur", "Lumbini" ])
    insights = Leads::ItineraryInsights.new(month: Date.new(2026, 11, 1))
    assert_equal [ [ "Chitwan + Kathmandu", 3 ], [ "Chitwan + Pokhara", 3 ], [ "Kathmandu + Pokhara", 3 ] ], insights.combinations

    designer_lead([ "Kathmandu", "Bandipur", "Lumbini" ])
    insights = Leads::ItineraryInsights.new(month: Date.new(2026, 11, 1))
    assert_equal 5, insights.built
    assert_equal [ [ "Kathmandu", 5 ], [ "Chitwan", 3 ], [ "Pokhara", 3 ], [ "Bandipur", 2 ], [ "Lumbini", 2 ] ], insights.stops
    assert_equal [ [ "Chitwan + Pokhara", 3 ], [ "Bandipur + Lumbini", 2 ] ], insights.combinations
  end

  test "a stop listed twice in one itinerary counts once and spellings merge" do
    designer_lead([ "Kathmandu", "Pokhara", "kathmandu" ], "season" => "fall", "pace" => "easy", "length_days" => 7)
    designer_lead([ "KATHMANDU", "Chitwan" ], "length_days" => 10)
    insights = Leads::ItineraryInsights.new(month: Date.new(2026, 11, 1))
    assert_equal [ "Kathmandu", 2 ], insights.stops.first
    assert_equal [ [ "About 1 week", 1 ], [ "About 10 days", 1 ] ], insights.lengths
    assert_equal [ "Fall (October to December)", 1 ], insights.seasons.second
    assert_equal [ "Not given", 1 ], insights.seasons.last
    assert_equal [ [ "Not given", 2 ] ], insights.sources
  end
end
