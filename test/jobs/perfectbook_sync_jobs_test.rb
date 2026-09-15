require "test_helper"
require_relative "../../db/seeds/demo_seed"

FakePbPage = Struct.new(:data, keyword_init: true)

class FakePbCatalogClient
  attr_reader :contacts_params

  def initialize(trips: [], departures: [], contacts: [], bookings_by_contact: {}, not_modified: {})
    @trips = trips
    @departures = departures
    @contacts = contacts
    @bookings_by_contact = bookings_by_contact
    @not_modified = not_modified
  end

  def list_trips(*)
    return { data: [], not_modified: true } if @not_modified[:trips]

    { data: @trips, not_modified: false }
  end

  def list_departures(*)
    return { data: [], not_modified: true } if @not_modified[:departures]

    { data: @departures, not_modified: false }
  end

  def list_contacts(updated_since: nil, **)
    @contacts_params = updated_since
    return { data: [], not_modified: true } if @not_modified[:contacts]

    { data: @contacts, not_modified: false }
  end

  def list_contact_bookings(contact_id, *)
    return { data: [], not_modified: true } if @not_modified[:"bookings_#{contact_id}"]

    { data: @bookings_by_contact[contact_id] || [], not_modified: false }
  end
end

def pb_trip(id: 1, name: "Everest Base Camp", active: true)
  PerfectBook::Client::Trip.new(id: id, name: name, active: active, status: active ? "active" : "inactive",
    shopify_product_id: "gid://shopify/1", departures_count: 1, departure_ids: [ 10 ],
    first_start_date: "2026-10-01", last_end_date: "2026-10-14",
    created_at: "2026-01-01T00:00:00Z", updated_at: "2026-02-01T00:00:00Z")
end

def pb_departure(id: 10, trip_id: 1)
  PerfectBook::Client::Departure.new(id: id, trip_id: trip_id, trip_name: "Everest Base Camp",
    label: "Everest · Lukla · Oct", start_date: "2026-10-01", end_date: "2026-10-14",
    duration_days: 14, place: "Lukla", country_codes: [ "NP" ], status: "confirmed",
    seats: 12, booked_seats: 4, available_seats: 8, price_per_person_minor: nil,
    currency: "USD", created_at: "2026-01-01T00:00:00Z", updated_at: "2026-02-01T00:00:00Z")
end

def pb_contact(id: 7, kind: "customer", archived: false, updated_at: "2026-03-01T00:00:00Z")
  PerfectBook::Client::Contact.new(id: id, kind: kind, name: "Ama D.", email: "ama@example.test",
    phone: nil, country: "US", state: "CA", archived: archived,
    created_at: "2026-01-01T00:00:00Z", updated_at: updated_at)
end

def pb_booking(id: 11, status: "deposit_received", badge: "partially_paid", documents: nil, checklist: nil, missing_count: nil)
  PerfectBook::Client::Booking.new(id: id, ref: "BK-#{id}", status: status,
    trip_id: 1, trip_name: "Everest Base Camp", departure_id: 10, departure_place: "Lukla",
    start_date: "2026-10-01", end_date: "2026-10-14", party_size: 2,
    price_per_person_minor: 10000, total_minor: 20000, paid_minor: 5000,
    balance_due_minor: 15000, currency: "USD", invoice_badge: badge,
    invoice_number: "SH-2026-0001", payment_reference: "SH20260001",
    deep_link: "https://perfectbook.sherpaholidays.com/bookings/#{id}",
    documents: documents, checklist: checklist, missing_count: missing_count)
end

class PerfectBookSyncJobsTest < ActiveSupport::TestCase
  setup do
    PerfectBook::Circuit.reset!
  end

  test "successful empty bookings delete mirrors while 304 preserves them" do
    PerfectBook::Contact.create!(perfectbook_id: 7, kind: "customer", name: "Ama", synced_at: Time.current)
    PerfectBook::Booking.create!(perfectbook_id: 11, perfectbook_contact_id: 7, synced_at: Time.current)
    PerfectBook::SyncBookingsJob.perform_now(client: FakePbCatalogClient.new(not_modified: { bookings_7: true }))
    assert PerfectBook::Booking.exists?(perfectbook_id: 11)
    PerfectBook::SyncBookingsJob.perform_now(client: FakePbCatalogClient.new)
    assert_not PerfectBook::Booking.exists?(perfectbook_id: 11)
  end

  test "contacts watermark records poll start instead of completion" do
    start = Time.utc(2026, 9, 14, 12)
    time_traveler = self
    travel_to start do
      client = FakePbCatalogClient.new
      client.define_singleton_method(:list_contacts) do |**|
        time_traveler.travel 30.seconds
        { data: [], not_modified: false }
      end
      PerfectBook::SyncContactsJob.perform_now(client: client)
      assert_equal start, PerfectBook::SyncState.for("contacts").last_success_at
    end
  end

  test "bookings resume after the last completed contact on failure" do
    first = PerfectBook::Contact.create!(perfectbook_id: 7, kind: "customer", synced_at: Time.current)
    PerfectBook::Contact.create!(perfectbook_id: 8, kind: "customer", synced_at: Time.current)
    calls = []
    client = FakePbCatalogClient.new
    client.define_singleton_method(:list_contact_bookings) do |id|
      calls << id
      raise PerfectBook::UnavailableError, "offline" if id == 8
      { data: [], not_modified: false }
    end
    assert_raises(PerfectBook::UnavailableError) { PerfectBook::SyncBookingsJob.perform_now(client: client) }
    assert_equal first.id, PerfectBook::SyncState.for("bookings").contact_cursor
    client.define_singleton_method(:list_contact_bookings) do |id|
      calls << id
      { data: [], not_modified: false }
    end
    PerfectBook::SyncBookingsJob.perform_now(client: client)
    assert_equal [ 7, 8, 8 ], calls
    assert_nil PerfectBook::SyncState.for("bookings").contact_cursor
  end

  test "failed mirror writes do not commit validators" do
    committed = false
    client = FakePbCatalogClient.new
    client.define_singleton_method(:list_trips) do
      { data: [ pb_trip(id: nil) ], not_modified: false, commit_etags: -> { committed = true } }
    end
    assert_raises(ActiveRecord::RecordInvalid) { PerfectBook::SyncCatalogJob.perform_now(client: client) }
    assert_not committed
  end

  test "catalog sync inserts trips and departures" do
    client = FakePbCatalogClient.new(trips: [ pb_trip ], departures: [ pb_departure ])
    PerfectBook::SyncCatalogJob.perform_now(client: client)
    assert_equal "Everest Base Camp", PerfectBook::Trip.find_by(perfectbook_id: 1).name
    assert_equal 8, PerfectBook::Departure.find_by(perfectbook_id: 10).available_seats
    assert_not_nil PerfectBook::SyncState.for("catalog").last_success_at
  end

  test "catalog sync updates changed rows" do
    PerfectBook::Trip.create!(perfectbook_id: 1, name: "Old name", synced_at: Time.current)
    client = FakePbCatalogClient.new(trips: [ pb_trip(name: "New name") ], departures: [])
    PerfectBook::SyncCatalogJob.perform_now(client: client)
    assert_equal "New name", PerfectBook::Trip.find_by(perfectbook_id: 1).name
  end

  test "catalog sync is a no-op on 304" do
    PerfectBook::Trip.create!(perfectbook_id: 1, name: "Kept", synced_at: 2.days.ago)
    old_synced = PerfectBook::Trip.find_by(perfectbook_id: 1).synced_at
    client = FakePbCatalogClient.new(not_modified: { trips: true, departures: true })
    PerfectBook::SyncCatalogJob.perform_now(client: client)
    assert_equal "Kept", PerfectBook::Trip.find_by(perfectbook_id: 1).name
    assert_equal old_synced.to_i, PerfectBook::Trip.find_by(perfectbook_id: 1).synced_at.to_i
    assert_not_nil PerfectBook::SyncState.for("catalog").last_success_at
  end

  test "contacts sync inserts, updates, and flags archived" do
    PerfectBook::Contact.create!(perfectbook_id: 7, kind: "customer", name: "Old",
      email: "old@example.test", archived: false, synced_at: Time.current)
    client = FakePbCatalogClient.new(contacts: [
      pb_contact(id: 7, archived: true),
      pb_contact(id: 8, kind: "advisor")
    ])
    PerfectBook::SyncContactsJob.perform_now(client: client)
    assert PerfectBook::Contact.find_by(perfectbook_id: 7).archived?
    assert_equal "advisor", PerfectBook::Contact.find_by(perfectbook_id: 8).kind
  end

  test "contacts sync passes updated_since from the last success" do
    PerfectBook::SyncState.for("contacts").update!(last_success_at: Time.utc(2026, 5, 1))
    client = FakePbCatalogClient.new(contacts: [])
    PerfectBook::SyncContactsJob.perform_now(client: client)
    assert_equal Time.utc(2026, 5, 1), client.contacts_params
  end

  test "contacts sync is a no-op on 304 but still records success" do
    client = FakePbCatalogClient.new(not_modified: { contacts: true })
    PerfectBook::SyncContactsJob.perform_now(client: client)
    assert_not_nil PerfectBook::SyncState.for("contacts").last_success_at
  end

  test "bookings sync inserts and updates badge and status" do
    PerfectBook::Contact.create!(perfectbook_id: 7, kind: "customer", name: "Ama", synced_at: Time.current)
    PerfectBook::Booking.create!(perfectbook_id: 11, perfectbook_contact_id: 7, ref: "BK-11",
      status: "quoted", invoice_badge: "sent", synced_at: Time.current)
    client = FakePbCatalogClient.new(bookings_by_contact: { 7 => [ pb_booking ] })
    PerfectBook::SyncBookingsJob.perform_now(client: client)
    booking = PerfectBook::Booking.find_by(perfectbook_id: 11)
    assert_equal "deposit_received", booking.status
    assert_equal "partially_paid", booking.invoice_badge
    assert_equal "Lukla", booking.departure_place
  end

  test "bookings sync drops rows the server no longer returns" do
    PerfectBook::Contact.create!(perfectbook_id: 7, kind: "customer", name: "Ama", synced_at: Time.current)
    PerfectBook::Booking.create!(perfectbook_id: 99, perfectbook_contact_id: 7, ref: "GONE", synced_at: Time.current)
    client = FakePbCatalogClient.new(bookings_by_contact: { 7 => [ pb_booking ] })
    PerfectBook::SyncBookingsJob.perform_now(client: client)
    assert_nil PerfectBook::Booking.find_by(perfectbook_id: 99)
    assert_not_nil PerfectBook::Booking.find_by(perfectbook_id: 11)
  end

  test "bookings sync stores the documents summary and checklist flags" do
    PerfectBook::Contact.create!(perfectbook_id: 7, kind: "customer", name: "Ama", synced_at: Time.current)
    documents = { "travelers" => [
      { "id" => 3, "first_name" => "Ama",
        "documents" => [
          { "type" => "passport", "status" => "received", "received_at" => "2026-08-01" },
          { "type" => "visa", "status" => "missing", "received_at" => nil },
          { "type" => "insurance", "status" => "expiring", "received_at" => "2026-08-02" },
          { "type" => "waiver", "status" => "not_required", "received_at" => nil }
        ] }
    ], "missing_count" => 2 }
    checklist = [ { "key" => "payment", "label" => "Payment", "done" => true },
      { "key" => "waiver", "label" => "Waiver", "done" => false } ]
    client = FakePbCatalogClient.new(bookings_by_contact: { 7 => [ pb_booking(documents: documents, checklist: checklist, missing_count: 2) ] })
    PerfectBook::SyncBookingsJob.perform_now(client: client)
    booking = PerfectBook::Booking.find_by!(perfectbook_id: 11)
    assert_equal 2, booking.missing_count
    assert_equal "Ama", booking.travelers.first["first_name"]
    assert_equal [ "Ama: visa, insurance" ], booking.missing_lines
    assert_equal [ true, false ], booking.checklist_json.map { |item| item["done"] }
    assert_equal 2, booking.outstanding_count
  end

  test "bookings without a documents summary keep the legacy card" do
    PerfectBook::Contact.create!(perfectbook_id: 7, kind: "customer", name: "Ama", synced_at: Time.current)
    client = FakePbCatalogClient.new(bookings_by_contact: { 7 => [ pb_booking ] })
    PerfectBook::SyncBookingsJob.perform_now(client: client)
    booking = PerfectBook::Booking.find_by!(perfectbook_id: 11)
    assert_not booking.documents_ready?
    assert_equal 0, booking.outstanding_count
    assert_nil booking.missing_lines
  end

  test "failed sync records the error without wiping the last success" do
    PerfectBook::SyncState.for("contacts").update!(last_success_at: 1.day.ago)
    failing = Object.new
    def failing.list_contacts(*)
      raise PerfectBook::UnauthorizedError, "bad token"
    end
    # Non-retryable errors are recorded, not re-raised, so the queue stays quiet.
    PerfectBook::SyncContactsJob.perform_now(client: failing)
    state = PerfectBook::SyncState.for("contacts")
    assert_equal "bad token", state.last_error
    assert_not_nil state.last_error_at
    assert_not_nil state.last_success_at
  end

  test "synced demo trips survive reseeding and wiping" do
    assert_synced_demo_survives(PerfectBook::Trip, 9001) do
      PerfectBook::SyncCatalogJob.perform_now(client: FakePbCatalogClient.new(trips: [ pb_trip(id: 9001, name: "Real trip") ]))
    end
  end

  test "synced demo departures survive reseeding and wiping" do
    assert_synced_demo_survives(PerfectBook::Departure, 9101) do
      PerfectBook::SyncCatalogJob.perform_now(client: FakePbCatalogClient.new(departures: [ pb_departure(id: 9101) ]))
    end
  end

  test "synced demo contacts survive reseeding and wiping" do
    assert_synced_demo_survives(PerfectBook::Contact, 9501) do
      PerfectBook::SyncContactsJob.perform_now(client: FakePbCatalogClient.new(contacts: [ pb_contact(id: 9501) ]))
    end
  end

  test "synced demo bookings survive reseeding and wiping" do
    assert_synced_demo_survives(PerfectBook::Booking, 18_701) do
      PerfectBook::SyncBookingsJob.perform_now(perfectbook_contact_id: 9501,
        client: FakePbCatalogClient.new(bookings_by_contact: { 9501 => [ pb_booking(id: 18_701) ] }))
    end
  end

  test "sync rolls back mirror writes if demo ownership cannot be released" do
    DemoSeed.load!
    connection = ActiveRecord::Base.connection
    connection.execute(<<~SQL)
      CREATE TEMP TRIGGER reject_demo_release BEFORE DELETE ON demo_records
      BEGIN
        SELECT RAISE(ABORT, 'ownership release failed');
      END;
    SQL
    operations = [
      [ PerfectBook::Trip, 9001, -> {
        PerfectBook::SyncCatalogJob.perform_now(client: FakePbCatalogClient.new(trips: [ pb_trip(id: 9001) ]))
      } ],
      [ PerfectBook::Departure, 9101, -> {
        PerfectBook::SyncCatalogJob.perform_now(client: FakePbCatalogClient.new(departures: [ pb_departure(id: 9101) ]))
      } ],
      [ PerfectBook::Contact, 9501, -> {
        PerfectBook::SyncContactsJob.perform_now(client: FakePbCatalogClient.new(contacts: [ pb_contact(id: 9501) ]))
      } ],
      [ PerfectBook::Booking, 18_701, -> {
        PerfectBook::SyncBookingsJob.perform_now(perfectbook_contact_id: 9501,
          client: FakePbCatalogClient.new(bookings_by_contact: { 9501 => [ pb_booking(id: 18_701) ] }))
      } ]
    ]
    operations.each do |model, id, sync|
      mirror = model.find_by!(perfectbook_id: id)
      original = mirror.attributes
      assert_raises(ActiveRecord::StatementInvalid, &sync)
      assert_equal original, mirror.reload.attributes
      assert DemoRecord.exists?(record_type: model.name, record_id: mirror.id)
    end
  ensure
    connection&.execute("DROP TRIGGER IF EXISTS reject_demo_release")
  end

  test "not modified sync responses preserve demo ownership" do
    DemoSeed.load!
    markers = DemoRecord.order(:id).pluck(:record_type, :record_id)
    client = FakePbCatalogClient.new(not_modified: {
      trips: true, departures: true, contacts: true, bookings_9501: true
    })
    PerfectBook::SyncCatalogJob.perform_now(client: client)
    PerfectBook::SyncContactsJob.perform_now(client: client)
    PerfectBook::SyncBookingsJob.perform_now(client: client, perfectbook_contact_id: 9501)
    assert_equal markers, DemoRecord.order(:id).pluck(:record_type, :record_id)
    DemoSeed.wipe!
    assert_empty DemoRecord.all
  end

  private

  def assert_synced_demo_survives(model, perfectbook_id)
    DemoSeed.load!
    mirror = model.find_by!(perfectbook_id: perfectbook_id)
    yield
    synced = mirror.reload.attributes
    assert_not DemoRecord.exists?(record_type: model.name, record_id: mirror.id)
    error = assert_raises(RuntimeError) { DemoSeed.load! }
    assert_match "Demo seed collision", error.message
    assert_equal synced, mirror.reload.attributes
    DemoSeed.wipe!
    assert_equal synced, mirror.reload.attributes
  end

end
