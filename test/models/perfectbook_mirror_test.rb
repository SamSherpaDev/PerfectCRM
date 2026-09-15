require "test_helper"

class PerfectBookCatalogTest < ActiveSupport::TestCase
  setup do
    PerfectBook::Trip.create!(perfectbook_id: 9, name: "Active", active: true, synced_at: Time.current)
  end

  test "active trips come back ordered by name" do
    PerfectBook::Trip.create!(perfectbook_id: 2, name: "Langtang", active: true, synced_at: Time.current)
    PerfectBook::Trip.create!(perfectbook_id: 1, name: "Annapurna", active: true, synced_at: Time.current)
    PerfectBook::Trip.create!(perfectbook_id: 3, name: "Old", active: false, synced_at: Time.current)
    names = PerfectBook::Catalog.new.active_trips.map(&:name)
    assert_equal %w[Active Annapurna Langtang], names
  end

  test "upcoming departures skip the past but keep undated rows last" do
    today = Date.new(2026, 9, 15)
    PerfectBook::Departure.create!(perfectbook_id: 1, perfectbook_trip_id: 9, place: "Past", start_date: today - 10, synced_at: Time.current)
    PerfectBook::Departure.create!(perfectbook_id: 2, perfectbook_trip_id: 9, place: "Soon", start_date: today + 5, synced_at: Time.current)
    PerfectBook::Departure.create!(perfectbook_id: 3, perfectbook_trip_id: 9, place: "Undated", start_date: nil, synced_at: Time.current)
    catalog = PerfectBook::Catalog.new(today: today)
    assert_equal %w[Soon Undated], catalog.upcoming_departures.map(&:place)
  end

  test "departures for a trip stay scoped and upcoming" do
    today = Date.new(2026, 9, 15)
    PerfectBook::Departure.create!(perfectbook_id: 1, perfectbook_trip_id: 9, place: "A",
      start_date: today + 3, synced_at: Time.current)
    PerfectBook::Departure.create!(perfectbook_id: 2, perfectbook_trip_id: 9, place: "Old",
      start_date: today - 3, synced_at: Time.current)
    PerfectBook::Departure.create!(perfectbook_id: 3, perfectbook_trip_id: 4, place: "Other",
      start_date: today + 3, synced_at: Time.current)
    assert_equal %w[A], PerfectBook::Catalog.new(today: today).departures_for_trip(9).map(&:place)
  end

  test "available departures drop sold-out rows but keep unknown capacity" do
    today = Date.new(2026, 9, 15)
    PerfectBook::Departure.create!(perfectbook_id: 1, perfectbook_trip_id: 9, place: "Full", start_date: today + 1,
      seats: 10, booked_seats: 10, available_seats: 0, synced_at: Time.current)
    PerfectBook::Departure.create!(perfectbook_id: 2, perfectbook_trip_id: 9, place: "Room", start_date: today + 1,
      seats: 10, booked_seats: 4, available_seats: 6, synced_at: Time.current)
    PerfectBook::Departure.create!(perfectbook_id: 3, perfectbook_trip_id: 9, place: "Open", start_date: today + 1,
      seats: nil, available_seats: nil, synced_at: Time.current)
    PerfectBook::Trip.create!(perfectbook_id: 8, name: "Inactive", active: false, synced_at: Time.current)
    PerfectBook::Departure.create!(perfectbook_id: 4, perfectbook_trip_id: 8, place: "Inactive",
      start_date: today, available_seats: 4, synced_at: Time.current)
    catalog = PerfectBook::Catalog.new(today: today)
    assert_equal %w[Room], catalog.available_departures(limit: 1).map(&:place)
    assert_equal %w[Full], catalog.upcoming_departures(limit: 1).map(&:place)
    assert_equal %w[Room Open], PerfectBook::Catalog.new(today: today).available_departures.map(&:place)
  end
end

class PerfectBookHelpersTest < ActionView::TestCase
  include ApplicationHelper
  test "contact helper builds from the base URL" do
    old = ENV["PERFECTBOOK_BASE_URL"]
    ENV["PERFECTBOOK_BASE_URL"] = "https://pb.example.test"
    begin
      assert_equal "https://pb.example.test/contacts/7", perfectbook_contact_url(7)
    ensure
      ENV["PERFECTBOOK_BASE_URL"] = old
    end
  end

  test "booking helper reuses the stored deep link" do
    booking = PerfectBook::Booking.new(deep_link: "https://pb.example.test/bookings/11")
    assert_equal "https://pb.example.test/bookings/11", perfectbook_booking_url(booking)
  end
end

class PerfectBookMirrorTest < ActiveSupport::TestCase
  test "mirror tables enforce stable PerfectBook ids" do
    PerfectBook::Trip.create!(perfectbook_id: 1, name: "A", synced_at: Time.current)
    assert_raises(ActiveRecord::RecordInvalid) do
      PerfectBook::Trip.create!(perfectbook_id: 1, name: "Dupe", synced_at: Time.current)
    end
  end

  test "etag store round-trips per endpoint" do
    PerfectBook::EtagStore.write("GET /api/v1/trips?limit=100", '"v1"')
    assert_equal '"v1"', PerfectBook::EtagStore.read("GET /api/v1/trips?limit=100")
  end

  test "sync state tracks success and error separately" do
    PerfectBook::SyncState.record_success!("catalog")
    assert_not_nil PerfectBook::SyncState.for("catalog").last_success_at
    PerfectBook::SyncState.record_error!("catalog", "boom")
    assert_equal "boom", PerfectBook::SyncState.for("catalog").last_error
    assert_not_nil PerfectBook::SyncState.last_error_row
  end
end
