require "test_helper"

class PersonNamePropagationTest < ActiveSupport::TestCase
  test "renaming a lead updates its matching person, existing client, search index, open items, and timeline" do
    existing_client = Client.create!(name: "Elena Rossi", email: "traveler1@example.com")
    client_self_person = existing_client.people.create!(name: "Elena Rossi", email: "traveler1@example.com", role: "Lead traveler")

    lead = Lead.create!(
      name: "Elena Rossi",
      email: "traveler1@example.com",
      source: "website_form",
      existing_client: existing_client,
      message: "Hi, I am Elena Rossi asking about October."
    )
    lead_self_person = lead.people.create!(name: "Elena Rossi", email: "traveler1@example.com", role: "Lead traveler")
    companion = lead.people.create!(name: "Marco Bianchi", email: "companion1@example.com", role: "Spouse")

    open_task = lead.tasks.create!(title: "Call Elena about the November departure", due_on: Date.current)
    done_task = lead.tasks.create!(title: "Send brochure to Elena Rossi", due_on: Date.current - 1, done_at: 1.day.ago)
    scheduled_call = lead.scheduled_calls.create!(
      scheduled_at: 1.day.from_now,
      duration_minutes: 30,
      notes: "Confirm pace with Elena Rossi"
    )
    completed_call = lead.scheduled_calls.create!(
      scheduled_at: 2.days.ago,
      duration_minutes: 30,
      status: "completed",
      outcome: "connected",
      completed_at: 2.days.ago,
      notes: "Spoke with Elena Rossi"
    )
    draft = Draft.create!(
      owner: lead,
      to_addrs: "Elena Rossi <traveler1@example.com>",
      subject: "Dates for Elena Rossi",
      body: "Hi Elena,\n\nHere are the dates."
    )
    draft_quote = Quote.create!(
      lead: lead,
      status: "draft",
      trip_name: "Annapurna Sanctuary",
      party_size: 2,
      disclosure_details: { "travelers" => "Elena Rossi, Marco Bianchi" },
      notes: "Prepared for Elena Rossi"
    )

    # Simulate the lead edit form where Display name is changed and nested
    # people_attributes still submits the old name from the bottom of the form.
    lead.update!(
      name: "Sofia Conti",
      people_attributes: {
        "0" => { id: lead_self_person.id, name: "Elena Rossi", email: "traveler1@example.com", role: "Lead traveler" },
        "1" => { id: companion.id, name: "Marco Bianchi", email: "companion1@example.com", role: "Spouse" }
      }
    )

    assert_equal "Sofia Conti", lead.reload.name
    assert_equal "Sofia Conti", lead_self_person.reload.name
    assert_equal "Marco Bianchi", companion.reload.name
    assert_equal "Sofia Conti", existing_client.reload.name
    assert_equal "Sofia Conti", client_self_person.reload.name

    assert_includes Lead.search("Sofia Conti"), lead
    assert_not_includes Lead.search("Elena Rossi"), lead
    assert_includes Lead.fts_match_ids("Sofia"), lead.id
    assert_not_includes Lead.fts_match_ids("Elena"), lead.id
    assert_includes Client.search("Sofia Conti"), existing_client
    assert_not_includes Client.search("Elena Rossi"), existing_client

    assert_equal "Call Sofia about the November departure", open_task.reload.title
    assert_equal "Send brochure to Elena Rossi", done_task.reload.title
    assert_equal "Confirm pace with Sofia Conti", scheduled_call.reload.notes
    assert_equal "Spoke with Elena Rossi", completed_call.reload.notes
    assert_equal "Sofia Conti <traveler1@example.com>", draft.reload.to_addrs
    assert_equal "Dates for Sofia Conti", draft.subject
    assert_equal "Hi Sofia,\n\nHere are the dates.", draft.body
    assert_equal "Sofia Conti", draft_quote.reload.owner_name
    assert_equal "Sofia Conti, Marco Bianchi", draft_quote.disclosure_details["travelers"]
    assert_equal "Prepared for Sofia Conti", draft_quote.notes
    assert_equal "Hi, I am Elena Rossi asking about October.", lead.message

    events = lead.activity_events.where(kind: "name_change")
    assert_equal 1, events.count
    assert_equal "Name changed from Elena Rossi to Sofia Conti", events.first.summary
  end

  test "renaming a client updates converted leads, linked people, and FTS while keeping converted leads read-only" do
    lead = Lead.create!(name: "Tom Becker", email: "primary2@example.com", source: "google_ads")
    lead_person = lead.people.create!(name: "Tom Becker", email: "primary2@example.com", role: "Lead traveler")
    client = lead.convert_to_client!
    client_person = client.people.find_by!(origin_person_id: lead_person.id)

    prior_lead_events = lead.activity_events.pluck(:id, :summary)

    client.update!(
      name: "Lucas Schmidt",
      people_attributes: {
        "0" => { id: client_person.id, name: "Tom Becker", email: "primary2@example.com", role: "Lead traveler" }
      }
    )

    assert_equal "Lucas Schmidt", client.reload.name
    assert_equal "Lucas Schmidt", client_person.reload.name
    assert_equal "Lucas Schmidt", lead.reload.name
    assert_equal "Lucas Schmidt", lead_person.reload.name

    assert_includes Client.search("Lucas Schmidt"), client
    assert_not_includes Client.search("Tom Becker"), client
    assert_includes Lead.search("Lucas Schmidt"), lead
    assert_not_includes Lead.search("Tom Becker"), lead
    assert_includes Lead.fts_match_ids("Lucas"), lead.id
    assert_not_includes Lead.fts_match_ids("Tom"), lead.id

    assert_equal prior_lead_events, lead.activity_events.reload.pluck(:id, :summary)
    name_events = client.activity_events.where(kind: "name_change")
    assert_equal 1, name_events.count
    assert_equal "Name changed from Tom Becker to Lucas Schmidt", name_events.first.summary

    assert_not lead.update(trip_interest: "Forbidden edit")
    assert_includes lead.errors[:base], "Converted leads stay read-only"
  end

  test "editing a companion person updates linked origin people and FTS without renaming the primary owner" do
    lead = Lead.create!(name: "Jonas Hoffman", email: "primary3@example.com", source: "referral")
    lead_jonas = lead.people.create!(name: "Jonas Hoffman", email: "primary3@example.com", role: "Lead traveler")
    lead_lena = lead.people.create!(name: "Lena Weber", email: "partner3@example.com", role: "Partner")
    client = lead.convert_to_client!
    client_jonas = client.people.find_by!(origin_person_id: lead_jonas.id)
    client_lena = client.people.find_by!(origin_person_id: lead_lena.id)

    client.update!(
      name: "Jonas Hoffman",
      people_attributes: {
        "0" => { id: client_jonas.id, name: "Jonas Hoffman", email: "primary3@example.com", role: "Lead traveler" },
        "1" => { id: client_lena.id, name: "Clara Meyer", email: "partner3@example.com", role: "Partner" }
      }
    )

    assert_equal "Jonas Hoffman", client.reload.name
    assert_equal "Jonas Hoffman", client_jonas.reload.name
    assert_equal "Jonas Hoffman", lead.reload.name
    assert_equal "Jonas Hoffman", lead_jonas.reload.name
    assert_equal "Clara Meyer", client_lena.reload.name
    assert_equal "Clara Meyer", lead_lena.reload.name

    assert_includes Client.search("Clara Meyer"), client
    assert_not_includes Client.search("Lena Weber"), client
    assert_includes Lead.search("Clara Meyer"), lead
    assert_not_includes Lead.search("Lena Weber"), lead

    name_events = client.activity_events.where(kind: "name_change")
    assert_equal 1, name_events.count
    assert_equal "Name changed from Lena Weber to Clara Meyer", name_events.first.summary
  end

  test "editing the primary traveler under people updates the owner display name too" do
    client = Client.create!(name: "Amara Okafor", email: "amara@example.com")
    person = client.people.create!(name: "Amara Okafor", email: "amara@example.com", role: "Lead traveler")

    client.update!(
      name: "Amara Okafor",
      people_attributes: {
        "0" => { id: person.id, name: "Amara Nwosu", email: "amara@example.com", role: "Lead traveler" }
      }
    )

    assert_equal "Amara Nwosu", client.reload.name
    assert_equal "Amara Nwosu", person.reload.name
    assert_equal 1, client.activity_events.where(kind: "name_change").count
    assert_equal "Name changed from Amara Okafor to Amara Nwosu",
      client.activity_events.find_by!(kind: "name_change").summary
  end

  test "history and PerfectBook contacts stay untouched when a person is renamed" do
    pb_contact = PerfectBook::Contact.create!(
      perfectbook_id: 7701,
      name: "Amara Legal Okafor",
      email: "amara@example.com",
      synced_at: Time.current
    )
    client = Client.create!(
      name: "Amara Okafor",
      email: "amara@example.com",
      perfectbook_contact_id: pb_contact.perfectbook_id
    )
    conversation = client.conversations.create!(subject_line: "Everest booking")
    inbound_msg = conversation.messages.create!(
      direction: "in",
      status: "received",
      from_address: "amara@example.com",
      to_addresses: [ "info@sherpaholidays.com" ],
      subject: "From Amara Okafor",
      text_body: "Signed, Amara Okafor",
      message_id: "<in-amara@example.com>"
    )
    outbound_msg = conversation.messages.create!(
      direction: "out",
      status: "sent",
      from_address: "info@sherpaholidays.com",
      to_addresses: [ "Amara Okafor <amara@example.com>" ],
      subject: "Itinerary for Amara Okafor",
      text_body: "Hi Amara Okafor, attached is your itinerary.",
      message_id: "<out-amara@example.com>",
      sent_at: 1.day.ago
    )
    past_note = Note.create!(notable: client, body: "Met Amara Okafor in London")
    past_event = ActivityEvent.create!(
      subject: client,
      kind: "email",
      summary: "Sent welcome note to Amara Okafor",
      occurred_at: 2.days.ago
    )
    sent_quote = Quote.create!(
      client: client,
      status: "sent",
      trip_name: "Everest Base Camp",
      party_size: 2,
      sent_at: 1.day.ago,
      terms_bundle: {
        "terms_version" => QuoteTerms::VERSION,
        "client" => "Amara Okafor",
        "email" => "amara@example.com",
        "payment_now_minor" => 50_000,
        "remaining_balance_minor" => 200_000,
        "paid_to_date_minor" => 0
      },
      terms_bundle_sha256: "abc123",
      disclosure_details: { "travelers" => "Amara Okafor" },
      notes: "Sent to Amara Okafor"
    )
    accepted_quote = Quote.create!(
      client: client,
      status: "accepted",
      trip_name: "Langtang",
      party_size: 1,
      sent_at: 3.days.ago,
      accepted_at: 2.days.ago,
      terms_bundle: {
        "terms_version" => QuoteTerms::VERSION,
        "client" => "Amara Okafor",
        "email" => "amara@example.com",
        "payment_now_minor" => 50_000,
        "remaining_balance_minor" => 150_000,
        "paid_to_date_minor" => 0
      },
      terms_bundle_sha256: "def456",
      intake_payload: JSON.generate({ "client" => "Amara Okafor", "email" => "amara@example.com" })
    )

    client.update!(name: "Amara Nwosu")

    assert_equal "Amara Legal Okafor", pb_contact.reload.name
    assert_equal "From Amara Okafor", inbound_msg.reload.subject
    assert_equal "Signed, Amara Okafor", inbound_msg.text_body
    assert_equal [ "Amara Okafor <amara@example.com>" ], outbound_msg.reload.to_addresses
    assert_equal "Itinerary for Amara Okafor", outbound_msg.subject
    assert_equal "Hi Amara Okafor, attached is your itinerary.", outbound_msg.text_body
    assert_equal "Met Amara Okafor in London", past_note.reload.body
    assert_equal "Sent welcome note to Amara Okafor", past_event.reload.summary

    assert_equal "Amara Okafor", sent_quote.reload.owner_name
    assert_equal "Amara Okafor", sent_quote.disclosure_details["travelers"]
    assert_equal "Sent to Amara Okafor", sent_quote.notes
    assert_equal "Amara Okafor", accepted_quote.reload.owner_name
    assert_equal "Amara Okafor", accepted_quote.intake_details["client"]
  end

  test "renaming an organization refreshes FTS, updates open tasks, and logs one event" do
    org = Organization.create!(name: "Alpine Guides", kind: "advisor", email: "info@partner-org.example.com")
    task = org.tasks.create!(title: "Follow up with Alpine Guides", due_on: Date.current)

    org.update!(name: "Summit Expeditions")

    assert_includes Organization.search("Summit Expeditions"), org
    assert_not_includes Organization.search("Alpine Guides"), org
    assert_equal "Follow up with Summit Expeditions", task.reload.title
    event = org.activity_events.find_by!(kind: "name_change")
    assert_equal "Name changed from Alpine Guides to Summit Expeditions", event.summary
  end

  test "renaming one member of a shared household leaves the other person's linked records alone" do
    client = Client.create!(name: "John Smith", email: "household@example.com")
    john = client.people.create!(name: "John Smith", email: "household@example.com", role: "Lead traveler")
    lead = Lead.create!(name: "Jane Smith", email: "household@example.com", source: "website_form", existing_client: client)
    jane = lead.people.create!(name: "Jane Smith", email: "household@example.com", role: "Lead traveler")

    lead.update!(name: "Jane Doe")

    assert_equal "Jane Doe", lead.reload.name
    assert_equal "Jane Doe", jane.reload.name
    assert_equal "John Smith", client.reload.name
    assert_equal "John Smith", john.reload.name

    client.update!(name: "Johnny Smith")

    assert_equal "Johnny Smith", client.reload.name
    assert_equal "Johnny Smith", john.reload.name
    assert_equal "Jane Doe", lead.reload.name
    assert_equal "Jane Doe", jane.reload.name

    jane.update!(name: "Jane Roe")

    assert_equal "Jane Roe", lead.reload.name
    assert_equal "Johnny Smith", client.reload.name
    assert_equal "Johnny Smith", john.reload.name
  end

  test "renaming a client succeeds when its converted lead still holds a scheduled call" do
    lead = Lead.create!(name: "Tom Becker", email: "primary7@example.com", source: "google_ads")
    call = lead.scheduled_calls.create!(scheduled_at: 1.day.from_now, duration_minutes: 30, notes: "Call Tom about dates")
    client = lead.convert_to_client!

    assert client.update(name: "Thomas Becker"), client.errors.full_messages.to_sentence

    assert_equal "Thomas Becker", client.reload.name
    assert_equal "Thomas Becker", lead.reload.name
    assert_equal "Call Tom about dates", call.reload.notes
  end

  test "first-name rewrites skip organizations, companies, and owners who share the old first name" do
    org = Organization.create!(name: "Himalayan Footprints", kind: "operator")
    org_task = org.tasks.create!(title: "Confirm Himalayan permit with Himalayan Footprints", due_on: Date.current)
    org_draft = Draft.create!(owner: org, subject: "Himalayan Footprints dates", body: "Our Himalayan departures are full.")

    org.update!(name: "Summit Footprints")

    assert_equal "Confirm Himalayan permit with Summit Footprints", org_task.reload.title
    assert_equal "Summit Footprints dates", org_draft.reload.subject
    assert_equal "Our Himalayan departures are full.", org_draft.body

    company = Client.create!(name: "Himalayan Adventures", kind: "company", email: "office@example.com")
    company_task = company.tasks.create!(title: "Send Himalayan Adventures the Himalayan route", due_on: Date.current)

    company.update!(name: "Summit Adventures")

    assert_equal "Send Summit Adventures the Himalayan route", company_task.reload.title

    lead = Lead.create!(name: "Maria Lopez", email: "maria@example.com", source: "website_form")
    companion = lead.people.create!(name: "Maria Garcia", role: "Partner")
    lead_task = lead.tasks.create!(title: "Call Maria about deposit", notes: "Book Maria Garcia's flight", due_on: Date.current)

    lead.update!(people_attributes: { "0" => { id: companion.id, name: "Marta Garcia", role: "Partner" } })

    assert_equal "Marta Garcia", companion.reload.name
    assert_equal "Maria Lopez", lead.reload.name
    assert_equal "Call Maria about deposit", lead_task.reload.title
    assert_equal "Book Marta Garcia's flight", lead_task.notes
  end

  test "renaming keeps text that already holds the new name from doubling" do
    lead = Lead.create!(name: "Rossi", email: "rossi@example.com", source: "referral")
    task = lead.tasks.create!(title: "Call Elena Rossi", notes: "Ask Rossi about dates", due_on: Date.current)

    lead.update!(name: "Elena Rossi")

    assert_equal "Call Elena Rossi", task.reload.title
    assert_equal "Ask Elena Rossi about dates", task.notes

    task.update!(notes: "Maria Elena Rossi confirmed")
    lead.update!(name: "Maria Elena Rossi")

    assert_equal "Call Maria Elena Rossi", task.reload.title
    assert_equal "Maria Elena Rossi confirmed", task.notes
  end
end
