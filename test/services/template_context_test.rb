require "test_helper"

class TemplateContextTest < ActiveSupport::TestCase
  setup do
    @client = Client.create!(name: "Maya Gurung", email: "maya@example.com")
    Setting.current.update!(sender_name: "Sam", email_signature: "Sam Sherpa\nSherpa Holidays")
  end

  test "fills names from the record without a booking" do
    context = TemplateContext.for(@client)
    assert_equal "Maya", context["first_name"]
    assert_equal "Maya Gurung", context["full_name"]
  end

  test "fills sender name and signature from settings" do
    context = TemplateContext.for(@client)
    assert_equal "Sam", context["my_name"]
    assert_equal "Sam Sherpa\nSherpa Holidays", context["signature"]
  end

  test "fills advisor name from the referring organization" do
    org = Organization.create!(name: "Adventure Co.", email: "a@example.com")
    @client.update!(referred_by_organization: org)
    assert_equal "Adventure Co.", TemplateContext.for(@client)["advisor_name"]
  end

  test "omits unknown and empty values so the renderer marks them missing" do
    context = TemplateContext.for(@client)
    assert_nil context["trip"]
    assert_nil context["balance_due"]
    # deposit_due and missing_documents have no source yet: they stay
    # honest markers until a later task feeds them.
    assert_nil context["deposit_due"]
    assert_nil context["missing_documents"]
    rendered = Template.new(subject: "Hi {{first_name}}", body: "{{trip}} owes {{balance_due}} (deposit {{deposit_due}}, docs {{missing_documents}})").rendered(context)
    assert_equal "Hi Maya", rendered[:subject]
    assert_equal "[missing: trip] owes [missing: balance_due] (deposit [missing: deposit_due], docs [missing: missing_documents])", rendered[:body]
  end

  test "fills trip, dates, invoice, and reference from the booking" do
    booking = PerfectBook::Booking.create!(perfectbook_id: 9001, perfectbook_contact_id: 4242,
      trip_name: "Everest Base Camp trek", start_date: Date.new(2027, 5, 4), end_date: Date.new(2027, 5, 18),
      balance_due_minor: 185_000, currency: "USD", invoice_number: "SH-2027-0142",
      payment_reference: "SH-0142-MAYA", synced_at: Time.current, status: "deposit_received")
    @client.update!(perfectbook_contact_id: 4242)
    context = TemplateContext.for(@client)
    assert_equal "Everest Base Camp trek", context["trip"]
    assert_equal "May 4 – May 18, 2027", context["departure_dates"]
    assert_equal "$1,850.00", context["balance_due"]
    assert_equal "SH-2027-0142", context["invoice_number"]
    assert_equal "SH-0142-MAYA", context["payment_reference"]
  end

  test "chooses the most recent active booking by default and lets the captain pick another" do
    @client.update!(perfectbook_contact_id: 5150)
    old = PerfectBook::Booking.create!(perfectbook_id: 9101, perfectbook_contact_id: 5150,
      trip_name: "Annapurna Circuit", start_date: Date.new(2026, 10, 1), synced_at: Time.current, status: "completed")
    cancelled = PerfectBook::Booking.create!(perfectbook_id: 9102, perfectbook_contact_id: 5150,
      trip_name: "Langtang Valley", start_date: Date.new(2027, 9, 1), synced_at: Time.current, status: "cancelled")
    fresh = PerfectBook::Booking.create!(perfectbook_id: 9103, perfectbook_contact_id: 5150,
      trip_name: "Everest Base Camp trek", start_date: Date.new(2027, 5, 4), synced_at: Time.current, status: "deposit_received")

    assert_equal [ fresh, old, cancelled ], TemplateContext.bookings_for(@client)
    assert_equal "Everest Base Camp trek", TemplateContext.for(@client)["trip"]
    assert_equal "Annapurna Circuit", TemplateContext.for(@client, booking: old)["trip"]
  end

  test "formats single dates and non-USD money" do
    booking = PerfectBook::Booking.create!(perfectbook_id: 9201, perfectbook_contact_id: 6161,
      start_date: Date.new(2027, 5, 4), balance_due_minor: 14_000_000, currency: "NPR", synced_at: Time.current, status: "enquiry")
    lead = Lead.create!(name: "Pemba Sherpa", email: "pemba@example.com",
      source: "email", perfectbook_contact_id: 6161)
    context = TemplateContext.for(lead, booking: booking)
    assert_equal "May 4, 2027", context["departure_dates"]
    assert_equal "NPR 140,000.00", context["balance_due"]
  end

  test "works for leads and organizations without bookings" do
    lead = Lead.create!(name: "Tashi B", email: "tashi@example.com", source: "website_form")
    assert_equal "Tashi", TemplateContext.for(lead)["first_name"]
    org = Organization.create!(name: "Operator GmbH", email: "op@example.com")
    assert_equal "Operator GmbH", TemplateContext.for(org)["full_name"]
  end
  test "reply trip interest belongs only to the resolved lead and bookings take precedence" do
    lead = Lead.create!(name: "Annapurna lead", email: "annapurna@example.com",
      source: "manual", trip_interest: "Annapurna")
    other = Lead.create!(name: "Langtang lead", email: "langtang@example.com",
      source: "manual", trip_interest: "Langtang")

    assert_equal "Annapurna", TemplateContext.for_reply(to: lead.email, owner: lead)[:context]["trip"]
    assert_equal "Langtang", TemplateContext.for_reply(to: other.email, owner: lead)[:context]["trip"]
    assert_nil TemplateContext.for_reply(to: "stranger@example.com", owner: lead)[:context]["trip"]
    person = lead.people.create!(name: "Traveler", email: "traveler@example.com")
    assert_nil TemplateContext.for_reply(to: person.email, owner: lead)[:context]["trip"]

    lead.update!(perfectbook_contact_id: 7711)
    PerfectBook::Booking.create!(perfectbook_id: 7712, perfectbook_contact_id: 7711,
      trip_name: "Everest", synced_at: Time.current)
    assert_equal "Everest", TemplateContext.for_reply(to: lead.email, owner: lead)[:context]["trip"]
  end
  test "mirrored recipient retains matching lead trip interest without borrowing another lead trip" do
    lead = Lead.create!(name: "Annapurna lead", email: "annapurna@example.com",
      source: "manual", trip_interest: "Annapurna")
    PerfectBook::Contact.create!(perfectbook_id: 8811, name: "Mirrored lead",
      email: lead.email, synced_at: Time.current)
    PerfectBook::Contact.create!(perfectbook_id: 8812, name: "Other traveler",
      email: "other@example.com", synced_at: Time.current)

    context = TemplateContext.for_reply(to: "  ANNAPURNA@example.com  ", owner: lead)[:context]
    assert_equal "Mirrored lead", context["full_name"]
    assert_equal "Annapurna", context["trip"]
    assert_nil TemplateContext.for_reply(to: "other@example.com", owner: lead)[:context]["trip"]
    assert_nil TemplateContext.for_reply(to: "", owner: lead)[:context]["trip"]

    PerfectBook::Booking.create!(perfectbook_id: 8813, perfectbook_contact_id: 8811,
      trip_name: "Everest", synced_at: Time.current)
    assert_equal "Everest", TemplateContext.for_reply(to: lead.email, owner: lead)[:context]["trip"]

    lead.update!(email: nil)
    assert_nil TemplateContext.for_reply(to: "", owner: lead)[:context]["trip"]
  end

end
