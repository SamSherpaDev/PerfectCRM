require "test_helper"

class PersonNamePropagationTest < ActiveSupport::TestCase
  test "renaming a lead updates its matching person, existing client, search index, and timeline but keeps written text" do
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
    scheduled_call = lead.scheduled_calls.create!(
      scheduled_at: 1.day.from_now,
      duration_minutes: 30,
      notes: "Confirm pace with Elena Rossi"
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

    assert_equal "Call Elena Rossi about the November departure", open_task.reload.title
    assert_equal "Confirm pace with Elena Rossi", scheduled_call.reload.notes
    assert_equal "Elena Rossi <traveler1@example.com>", draft.reload.to_addrs
    assert_equal "Dates for Elena Rossi", draft.subject
    assert_equal "Hi Elena,\n\nHere are the dates.", draft.body
    assert_equal "Sofia Conti", draft_quote.reload.owner_name
    assert_equal "Elena Rossi, Marco Bianchi", draft_quote.disclosure_details["travelers"]
    assert_equal "Prepared for Elena Rossi", draft_quote.notes
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

  test "renaming an organization refreshes FTS, keeps open task wording, and logs one event" do
    org = Organization.create!(name: "Alpine Guides", kind: "advisor", email: "info@partner-org.example.com")
    task = org.tasks.create!(title: "Follow up with Alpine Guides", due_on: Date.current)

    org.update!(name: "Summit Expeditions")

    assert_includes Organization.search("Summit Expeditions"), org
    assert_not_includes Organization.search("Alpine Guides"), org
    assert_equal "Follow up with Alpine Guides", task.reload.title
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

  test "renaming a client keeps the wording of its open calls, including the ones carried over from its converted lead" do
    lead = Lead.create!(name: "Tom Becker", email: "primary7@example.com", source: "google_ads")
    carried_call = lead.scheduled_calls.create!(scheduled_at: 1.day.from_now, duration_minutes: 30, notes: "Call Tom Becker about dates")
    client = lead.convert_to_client!
    client_call = client.scheduled_calls.create!(scheduled_at: 2.days.from_now, duration_minutes: 30, notes: "Hi Tom, Tom Becker asked for a callback")

    assert client.update(name: "Thomas Becker"), client.errors.full_messages.to_sentence

    assert_equal "Thomas Becker", client.reload.name
    assert_equal "Thomas Becker", lead.reload.name
    assert_equal "Call Tom Becker about dates", carried_call.reload.notes
    assert_equal "Hi Tom, Tom Becker asked for a callback", client_call.reload.notes
    assert_equal 0, Current.name_change_skips.to_i
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

  test "relabeling a two-person display name leaves people and linked leads alone" do
    lead = Lead.create!(name: "Elena Rossi", email: "elena@example.com", source: "referral")
    lead_elena = lead.people.create!(name: "Elena Rossi", email: "elena@example.com", role: "Lead traveler")
    lead_marco = lead.people.create!(name: "Marco Bianchi", email: "marco@example.com", role: "Partner")
    client = lead.convert_to_client!
    elena = client.people.find_by!(origin_person_id: lead_elena.id)
    marco = client.people.find_by!(origin_person_id: lead_marco.id)

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
  end

  test "renaming a one-person client carries to her person and linked records" do
    client = Client.create!(name: "Ana Diaz", email: "ana.d@example.com")
    person = client.people.create!(name: "Ana Diaz", email: "ana.d@example.com", role: "Lead traveler")
    lead = Lead.create!(name: "Ana Diaz", email: "ana.d@example.com", source: "website_form", existing_client: client)
    lead_person = lead.people.create!(name: "Ana Diaz", email: "ana.d@example.com", role: "Lead traveler")

    client.update!(
      name: "Ana Díaz",
      people_attributes: { "0" => { id: person.id, name: "Ana Diaz", email: "ana.d@example.com", role: "Lead traveler" } }
    )

    assert_equal "Ana Díaz", client.reload.name
    assert_equal "Ana Díaz", person.reload.name
    assert_equal "Ana Díaz", lead.reload.name
    assert_equal "Ana Díaz", lead_person.reload.name
  end

  test "renaming the only person carrying a two-person display name renames it and its converted lead" do
    lead = Lead.create!(name: "Tom Becker", email: "tom@example.com", source: "referral")
    lead_tom = lead.people.create!(name: "Tom Becker", email: "tom@example.com", role: "Lead traveler")
    lead_lena = lead.people.create!(name: "Lena Weber", email: "lena@example.com", role: "Spouse")
    client = lead.convert_to_client!
    tom = client.people.find_by!(origin_person_id: lead_tom.id)
    lena = client.people.find_by!(origin_person_id: lead_lena.id)

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
    assert_equal 1, client.activity_events.where(kind: "name_change").count
  end

  test "adding the first person to a record leaves its display name alone" do
    lead = Lead.create!(name: "Maria Lopez", email: "maria@example.com", source: "website_form")

    lead.update!(people_attributes: { "0" => { name: "Carlos Lopez", email: "carlos@example.com", role: "Spouse" } })

    assert_equal "Maria Lopez", lead.reload.name
    assert_equal [ "Carlos Lopez" ], lead.people.map(&:name)
    assert_equal 0, lead.activity_events.where(kind: "name_change").count
  end

  test "renaming a record with no people while adding its first person under the new name carries the rename" do
    client = Client.create!(name: "Maria", email: "maria.l@example.com")
    lead = Lead.create!(name: "Maria", email: "maria.l@example.com", source: "website_form")

    lead.update!(
      name: "Maria Lopez",
      people_attributes: { "0" => { name: "Maria Lopez", email: "maria.l@example.com", role: "Lead traveler" } }
    )

    assert_equal "Maria Lopez", lead.reload.name
    assert_equal [ "Maria Lopez" ], lead.people.map(&:name)
    assert_equal "Maria Lopez", client.reload.name
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

  test "a rename leaves recipient and traveler lists exactly as written" do
    lead = Lead.create!(name: "Maria", email: "maria@x.com", source: "email")
    draft = Draft.create!(owner: lead, to_addrs: "Maria <maria@x.com>", cc_addrs: "Maria <maria@x.com>, Maria Garcia <mg@x.com>",
      body: "Here are the dates.")
    quote = Quote.create!(lead: lead, status: "draft", trip_name: "Annapurna Sanctuary", party_size: 2,
      disclosure_details: { "travelers" => "Maria, Maria Garcia" })

    lead.update!(name: "Maria Lopez")

    assert_equal "Maria Lopez", lead.reload.name
    assert_includes Lead.search("Maria Lopez"), lead
    assert_equal "Maria <maria@x.com>", draft.reload.to_addrs
    assert_equal "Maria <maria@x.com>, Maria Garcia <mg@x.com>", draft.cc_addrs
    assert_equal "Maria, Maria Garcia", quote.reload.disclosure_details["travelers"]
  end

  test "a rename leaves a longer name in task notes exactly as written" do
    lead = Lead.create!(name: "Robert Chen", email: "robert@example.com", source: "referral")
    task = lead.tasks.create!(title: "Book flights", notes: "Seat Robert Chen Jr. next to his father", due_on: Date.current)

    lead.update!(name: "Bob Chen")

    assert_equal "Bob Chen", lead.reload.name
    assert_equal "Seat Robert Chen Jr. next to his father", task.reload.notes
  end
end
