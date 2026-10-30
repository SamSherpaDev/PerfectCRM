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

    open_task = lead.tasks.create!(title: "Call Elena Rossi about the November departure", due_on: Date.current)
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

    # Simulate the lead edit form where Display name and the traveler's own
    # People row are changed together while the companion row stays as is.
    lead.update!(
      name: "Sofia Conti",
      people_attributes: {
        "0" => { id: lead_self_person.id, name: "Sofia Conti", email: "traveler1@example.com", role: "Lead traveler" },
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

    assert_equal "Call Sofia Conti about the November departure", open_task.reload.title
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
    call = lead.scheduled_calls.create!(scheduled_at: 1.day.from_now, duration_minutes: 30, notes: "Call Tom Becker about dates")
    client = lead.convert_to_client!

    assert client.update(name: "Thomas Becker"), client.errors.full_messages.to_sentence

    assert_equal "Thomas Becker", client.reload.name
    assert_equal "Thomas Becker", lead.reload.name
    assert_equal "Call Tom Becker about dates", call.reload.notes
    assert_equal 0, Current.name_change_skips.to_i
  end

  test "first-name rewrites skip organizations, companies, and owners who share the old first name" do
    org = Organization.create!(name: "Himalayan Footprints", kind: "operator")
    org_task = org.tasks.create!(title: "Confirm Himalayan permit with Himalayan Footprints", due_on: Date.current)
    org_draft = Draft.create!(owner: org, subject: "Himalayan Footprints dates", body: "Dear Himalayan partners,\nOur Himalayan departures are full.")

    org.update!(name: "Summit Footprints")

    assert_equal "Confirm Himalayan permit with Summit Footprints", org_task.reload.title
    assert_equal "Summit Footprints dates", org_draft.reload.subject
    assert_equal "Dear Himalayan partners,\nOur Himalayan departures are full.", org_draft.body

    company = Client.create!(name: "Himalayan Adventures", kind: "company", email: "office@example.com")
    company_task = company.tasks.create!(title: "Send Himalayan Adventures the Himalayan route", notes: "Hi Himalayan team", due_on: Date.current)

    company.update!(name: "Summit Adventures")

    assert_equal "Send Summit Adventures the Himalayan route", company_task.reload.title
    assert_equal "Hi Himalayan team", company_task.notes

    lead = Lead.create!(name: "Maria Lopez", email: "maria@example.com", source: "website_form")
    companion = lead.people.create!(name: "Maria Garcia", role: "Partner")
    lead_task = lead.tasks.create!(title: "Call Maria about deposit", notes: "Hi Maria,\nBook Maria Garcia's flight", due_on: Date.current)

    lead.update!(people_attributes: { "0" => { id: companion.id, name: "Marta Garcia", role: "Partner" } })

    assert_equal "Marta Garcia", companion.reload.name
    assert_equal "Maria Lopez", lead.reload.name
    assert_equal "Call Maria about deposit", lead_task.reload.title
    assert_equal "Hi Maria,\nBook Marta Garcia's flight", lead_task.notes
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

  test "renaming to a shortened name replaces the longer old name" do
    lead = Lead.create!(name: "Elena Rossi Bianchi", email: "bianchi@example.com", source: "referral")
    task = lead.tasks.create!(title: "Call Elena Rossi Bianchi about dates", due_on: Date.current)

    lead.update!(name: "Elena Rossi")

    assert_equal "Call Elena Rossi about dates", task.reload.title
  end

  test "first names are rewritten only in a leading salutation" do
    lead = Lead.create!(name: "June Park", email: "june@example.com", source: "website_form")
    draft = Draft.create!(owner: lead, subject: "June Park trip", body: "Hi June,\n\nThe June departure is full.")

    lead.update!(name: "Jun Park")

    assert_equal "Jun Park trip", draft.reload.subject
    assert_equal "Hi Jun,\n\nThe June departure is full.", draft.body
  end

  test "rewriting a submitted draft keeps it eligible for cleanup once the message sends" do
    lead = Lead.create!(name: "Priya Shah", email: "priya@example.com", source: "website_form")
    conversation = lead.conversations.create!(subject_line: "Trip dates")
    draft = Draft.create!(owner: lead, conversation: conversation, to_addrs: "priya@example.com",
      subject: "Dates", body: "Hi Priya Shah,\n\nHere are the dates.")
    message = conversation.messages.create!(
      direction: "out",
      status: "sending",
      from_address: "info@sherpaholidays.com",
      to_addresses: [ "priya@example.com" ],
      subject: "Dates",
      text_body: "Hi Priya Shah,\n\nHere are the dates.",
      submitted_draft_id: draft.id,
      submitted_draft_updated_at: draft.reload.updated_at
    )

    lead.update!(name: "Priya Mehta")

    assert_equal "Hi Priya Mehta,\n\nHere are the dates.", draft.reload.body
    message.mark_sent!
    assert_not Draft.exists?(draft.id)
  end

  test "a linked record that fails validation keeps the old name without blocking the rename" do
    client = Client.create!(name: "Ana Diaz", email: "ana@example.com", perfectbook_contact_id: 10)
    lead = Lead.create!(name: "Ana Diaz", email: "ana@example.com", source: "website_form",
      perfectbook_contact_id: 10, existing_client: client)
    client.update!(perfectbook_contact_id: 11)

    assert client.update(name: "Ana Díaz"), client.errors.full_messages.to_sentence

    assert_equal "Ana Díaz", client.reload.name
    assert_equal "Ana Diaz", lead.reload.name
    assert_equal 1, Current.name_change_skips
  end

  test "renaming one of two same-name people on an owner leaves the namesake and the owner alone" do
    lead = Lead.create!(name: "Robert Chen", email: "robert.sr@example.com", source: "referral")
    lead_father = lead.people.create!(name: "Robert Chen", email: "robert.sr@example.com", role: "Lead traveler")
    lead_son = lead.people.create!(name: "Robert Chen", email: "robert.jr@example.com", role: "Son")
    client = lead.convert_to_client!
    father = client.people.find_by!(origin_person_id: lead_father.id)
    son = client.people.find_by!(origin_person_id: lead_son.id)

    client.update!(
      name: "Robert Chen",
      people_attributes: {
        "0" => { id: father.id, name: "Robert Chen", email: "robert.sr@example.com", role: "Lead traveler" },
        "1" => { id: son.id, name: "Robert Chen Jr.", email: "robert.jr@example.com", role: "Son" }
      }
    )

    assert_equal "Robert Chen Jr.", son.reload.name
    assert_equal "Robert Chen Jr.", lead_son.reload.name
    assert_equal "Robert Chen", father.reload.name
    assert_equal "Robert Chen", lead_father.reload.name
    assert_equal "Robert Chen", client.reload.name
    assert_equal "Robert Chen", lead.reload.name
  end

  test "renaming the display name and one namesake together leaves the other namesake alone" do
    lead = Lead.create!(name: "Robert Chen", email: "robert.sr@example.com", source: "referral")
    lead_father = lead.people.create!(name: "Robert Chen", email: "robert.sr@example.com", role: "Lead traveler")
    lead_son = lead.people.create!(name: "Robert Chen", email: "robert.jr@example.com", role: "Son")
    client = lead.convert_to_client!
    father = client.people.find_by!(origin_person_id: lead_father.id)
    son = client.people.find_by!(origin_person_id: lead_son.id)

    client.update!(
      name: "Robert Chen Sr.",
      people_attributes: {
        "0" => { id: father.id, name: "Robert Chen Sr.", email: "robert.sr@example.com", role: "Lead traveler" },
        "1" => { id: son.id, name: "Robert Chen", email: "robert.jr@example.com", role: "Son" }
      }
    )

    assert_equal "Robert Chen Sr.", client.reload.name
    assert_equal "Robert Chen Sr.", father.reload.name
    assert_equal "Robert Chen Sr.", lead_father.reload.name
    assert_equal "Robert Chen", son.reload.name
    assert_equal "Robert Chen", lead_son.reload.name
  end

  test "relabeling a two-person display name leaves people, drafts, and linked leads alone" do
    lead = Lead.create!(name: "Elena Rossi", email: "elena@example.com", source: "referral")
    lead_elena = lead.people.create!(name: "Elena Rossi", email: "elena@example.com", role: "Lead traveler")
    lead_marco = lead.people.create!(name: "Marco Bianchi", email: "marco@example.com", role: "Partner")
    client = lead.convert_to_client!
    elena = client.people.find_by!(origin_person_id: lead_elena.id)
    marco = client.people.find_by!(origin_person_id: lead_marco.id)
    draft = Draft.create!(owner: client, to_addrs: "Elena Rossi <elena@example.com>",
      subject: "Dates for Elena Rossi", body: "Hi Elena,\n\nHere are the dates.")

    client.update!(
      name: "Rossi Family",
      people_attributes: {
        "0" => { id: elena.id, name: "Elena Rossi", email: "elena@example.com", role: "Lead traveler" },
        "1" => { id: marco.id, name: "Marco Bianchi", email: "marco@example.com", role: "Partner" }
      }
    )

    assert_equal "Rossi Family", client.reload.name
    assert_equal "Elena Rossi", elena.reload.name
    assert_equal "Marco Bianchi", marco.reload.name
    assert_equal "Elena Rossi", lead.reload.name
    assert_equal "Elena Rossi", lead_elena.reload.name
    assert_equal "Elena Rossi <elena@example.com>", draft.reload.to_addrs
    assert_equal "Dates for Elena Rossi", draft.subject
    assert_equal "Hi Elena,\n\nHere are the dates.", draft.body
  end

  test "renaming a one-person client carries to her person and linked records" do
    client = Client.create!(name: "Ana Diaz", email: "ana.d@example.com")
    person = client.people.create!(name: "Ana Diaz", email: "ana.d@example.com", role: "Lead traveler")
    lead = Lead.create!(name: "Ana Diaz", email: "ana.d@example.com", source: "website_form", existing_client: client)
    lead_person = lead.people.create!(name: "Ana Diaz", email: "ana.d@example.com", role: "Lead traveler")
    task = lead.tasks.create!(title: "Send Ana Diaz the dates", due_on: Date.current)

    client.update!(
      name: "Ana Díaz",
      people_attributes: { "0" => { id: person.id, name: "Ana Diaz", email: "ana.d@example.com", role: "Lead traveler" } }
    )

    assert_equal "Ana Díaz", client.reload.name
    assert_equal "Ana Díaz", person.reload.name
    assert_equal "Ana Díaz", lead.reload.name
    assert_equal "Ana Díaz", lead_person.reload.name
    assert_equal "Send Ana Díaz the dates", task.reload.title
  end

  test "renaming the only person carrying a two-person display name renames it and its converted lead" do
    lead = Lead.create!(name: "Tom Becker", email: "tom@example.com", source: "referral")
    lead_tom = lead.people.create!(name: "Tom Becker", email: "tom@example.com", role: "Lead traveler")
    lead_lena = lead.people.create!(name: "Lena Weber", email: "lena@example.com", role: "Spouse")
    client = lead.convert_to_client!
    tom = client.people.find_by!(origin_person_id: lead_tom.id)
    lena = client.people.find_by!(origin_person_id: lead_lena.id)
    task = client.tasks.create!(title: "Call Tom Becker about dates", due_on: Date.current)
    draft = Draft.create!(owner: client, to_addrs: "Tom Becker <tom@example.com>",
      subject: "Dates for Tom Becker", body: "Hi Tom,\n\nHere are the dates.")

    client.update!(
      name: "Tom Becker",
      people_attributes: {
        "0" => { id: tom.id, name: "Thomas Becker", email: "tom@example.com", role: "Lead traveler" },
        "1" => { id: lena.id, name: "Lena Weber", email: "lena@example.com", role: "Spouse" }
      }
    )

    assert_equal "Thomas Becker", client.reload.name
    assert_equal "Thomas Becker", tom.reload.name
    assert_equal "Thomas Becker", lead.reload.name
    assert_equal "Thomas Becker", lead_tom.reload.name
    assert_equal "Lena Weber", lena.reload.name
    assert_equal "Lena Weber", lead_lena.reload.name
    assert_equal "Call Thomas Becker about dates", task.reload.title
    assert_equal "Thomas Becker <tom@example.com>", draft.reload.to_addrs
    assert_equal "Dates for Thomas Becker", draft.subject
    assert_equal "Hi Thomas,\n\nHere are the dates.", draft.body
    assert_equal 1, client.activity_events.where(kind: "name_change").count
  end

  test "adding the first person to a record leaves its display name and drafts alone" do
    lead = Lead.create!(name: "Maria Lopez", email: "maria@example.com", source: "website_form")
    draft = Draft.create!(owner: lead, to_addrs: "Maria Lopez <maria@example.com>", body: "Hi Maria,\n\nHere are the dates.")

    lead.update!(people_attributes: { "0" => { name: "Carlos Lopez", email: "carlos@example.com", role: "Spouse" } })

    assert_equal "Maria Lopez", lead.reload.name
    assert_equal [ "Carlos Lopez" ], lead.people.map(&:name)
    assert_equal "Maria Lopez <maria@example.com>", draft.reload.to_addrs
    assert_equal "Hi Maria,\n\nHere are the dates.", draft.body
    assert_equal 0, lead.activity_events.where(kind: "name_change").count
  end

  test "renaming a record with no people while adding its first person under the new name carries the rename" do
    lead = Lead.create!(name: "Maria", email: "maria.l@example.com", source: "website_form")
    task = lead.tasks.create!(title: "Reply to Maria", due_on: Date.current)
    draft = Draft.create!(owner: lead, to_addrs: "Maria <maria.l@example.com>", body: "Here are the dates.")

    lead.update!(
      name: "Maria Lopez",
      people_attributes: { "0" => { name: "Maria Lopez", email: "maria.l@example.com", role: "Lead traveler" } }
    )

    assert_equal "Maria Lopez", lead.reload.name
    assert_equal [ "Maria Lopez" ], lead.people.map(&:name)
    assert_equal "Reply to Maria Lopez", task.reload.title
    assert_equal "Maria Lopez <maria.l@example.com>", draft.reload.to_addrs
  end

  test "relabeling a one-person display name while adding a second person keeps the first person's name" do
    lead = Lead.create!(name: "Tom Becker", email: "tom.b@example.com", source: "referral")
    lead_tom = lead.people.create!(name: "Tom Becker", email: "tom.b@example.com", role: "Lead traveler")
    client = lead.convert_to_client!
    tom = client.people.find_by!(origin_person_id: lead_tom.id)

    client.update!(
      name: "Becker Family",
      people_attributes: {
        "0" => { id: tom.id, name: "Tom Becker", email: "tom.b@example.com", role: "Lead traveler" },
        "1" => { name: "Lena Becker", email: "lena.b@example.com", role: "Spouse" }
      }
    )

    assert_equal "Becker Family", client.reload.name
    assert_equal "Tom Becker", tom.reload.name
    assert_equal "Tom Becker", lead.reload.name
    assert_equal "Tom Becker", lead_tom.reload.name
  end

  test "names followed by a sentence-ending period are replaced without touching addresses" do
    lead = Lead.create!(name: "Rossi", email: "rossi@example.com", source: "referral")
    task = lead.tasks.create!(title: "Follow up with Rossi.", notes: "Met Rossi. Site rossi.travel, mail rossi@example.com",
      due_on: Date.current)

    lead.update!(name: "Conti")

    assert_equal "Follow up with Conti.", task.reload.title
    assert_equal "Met Conti. Site rossi.travel, mail rossi@example.com", task.notes
  end
end
