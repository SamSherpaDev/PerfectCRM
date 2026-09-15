# Builds (and wipes) the demo dataset. Loaded through db/seeds/demo.rb,
# which owns the DEMO_SEED=1 guard; this file holds the logic so tests can
# call DemoSeed.load! directly.
module DemoSeed
  DEMO_DOMAIN = "demo.example.test".freeze

  module_function

  def load!
    ActiveRecord::Base.transaction do
      operator = Organization.find_or_create_by!(email: "namaste@#{DEMO_DOMAIN}") do |org|
        org.name = "Himalayan Footprints"
        org.kind = "operator"
        org.website = "https://himalayan-footprints.example.test"
      end
      advisor = Organization.find_or_create_by!(email: "maya@#{DEMO_DOMAIN}") do |org|
        org.name = "Maya Gurung Travels"
        org.kind = "advisor"
      end

      seed_catalog!
      clients = seed_clients!(operator, advisor)
      leads = seed_leads!(advisor)
      seed_conversations!(clients, leads)
      seed_quotes!(clients, leads)
      seed_tasks!(clients, leads)
      seed_notes!(clients, leads)
      seed_sync_states!
    end
  end

  # Deletes only demo rows. Demo clients, leads, and organizations all
  # use @demo.example.test emails; quotes hang off those owners and are
  # deleted first (no dependent destroy from the owner side), everything
  # else (conversations, messages, tasks, notes, activity) goes through
  # dependent destroys. Mirrored PerfectBook rows use reserved
  # perfectbook_ids (>= 9000) and are deleted directly.
  def wipe!
    ActiveRecord::Base.transaction do
      client_ids = Client.where("email LIKE ?", "%@#{DEMO_DOMAIN}").pluck(:id)
      lead_ids = Lead.where("email LIKE ?", "%@#{DEMO_DOMAIN}").pluck(:id)
      # ActivityEvent is append-only and readonly: clear demo rows directly.
      ActivityEvent.where(subject_type: "Client", subject_id: client_ids).delete_all
      ActivityEvent.where(subject_type: "Lead", subject_id: lead_ids).delete_all
      # destroy_all (not delete_all): quote lines and views go through callbacks.
      Quote.where(client_id: client_ids).destroy_all
      Quote.where(lead_id: lead_ids).destroy_all
      # Leads before clients: a converted lead still points at its client.
      Lead.where(id: lead_ids).destroy_all
      Client.where(id: client_ids).destroy_all
      Organization.where("email LIKE ?", "%@#{DEMO_DOMAIN}").destroy_all
      PerfectBook::Trip.where("perfectbook_id >= 9000").delete_all
      PerfectBook::Departure.where("perfectbook_id >= 9000").delete_all
      PerfectBook::Booking.where("perfectbook_id >= 9000").delete_all
      PerfectBook::Contact.where("perfectbook_id >= 9000").delete_all
    end
  end

  def seed_catalog!
    now = Time.current
    ebc = PerfectBook::Trip.find_or_create_by!(perfectbook_id: 9001) do |trip|
      trip.name = "Everest Base Camp trek"
      trip.status = "active"
      trip.active = true
      trip.synced_at = now
    end
    annapurna = PerfectBook::Trip.find_or_create_by!(perfectbook_id: 9002) do |trip|
      trip.name = "Annapurna Circuit trek"
      trip.status = "active"
      trip.active = true
      trip.synced_at = now
    end
    langtang = PerfectBook::Trip.find_or_create_by!(perfectbook_id: 9003) do |trip|
      trip.name = "Langtang Valley trek"
      trip.status = "active"
      trip.active = true
      trip.synced_at = now
    end
    departures = [
      { perfectbook_id: 9101, trip: ebc, label: "October departure", place: "Lukla",
        start_date: Date.new(2026, 10, 12), end_date: Date.new(2026, 10, 25),
        duration_days: 14, price_per_person_minor: 185_000, seats: 12, booked_seats: 7 },
      { perfectbook_id: 9102, trip: annapurna, label: "November departure", place: "Pokhara",
        start_date: Date.new(2026, 11, 3), end_date: Date.new(2026, 11, 18),
        duration_days: 16, price_per_person_minor: 179_000, seats: 12, booked_seats: 9 },
      { perfectbook_id: 9103, trip: langtang, label: "March departure", place: "Syabrubesi",
        start_date: Date.new(2027, 3, 21), end_date: Date.new(2027, 3, 30),
        duration_days: 10, price_per_person_minor: 129_000, seats: 10, booked_seats: 2 },
      { perfectbook_id: 9104, trip: ebc, label: "April departure", place: "Lukla",
        start_date: Date.new(2027, 4, 5), end_date: Date.new(2027, 4, 18),
        duration_days: 14, price_per_person_minor: 189_000, seats: 12, booked_seats: 1 }
    ]
    departures.each do |attrs|
      trip = attrs.delete(:trip)
      dep = PerfectBook::Departure.find_or_initialize_by(perfectbook_id: attrs[:perfectbook_id])
      dep.assign_attributes(attrs.merge(
        perfectbook_trip_id: trip.perfectbook_id, trip_name: trip.name,
        currency: "USD", status: "open", synced_at: now,
        available_seats: attrs[:seats] - attrs[:booked_seats]
      ))
      dep.save!
    end
    [ ebc, annapurna, langtang ].each do |trip|
      ids = PerfectBook::Departure.where(perfectbook_trip_id: trip.perfectbook_id).pluck(:perfectbook_id)
      trip.update!(departure_ids: ids, departures_count: ids.size,
        first_start_date: PerfectBook::Departure.where(perfectbook_id: ids).minimum(:start_date),
        last_end_date: PerfectBook::Departure.where(perfectbook_id: ids).maximum(:end_date))
    end
  end

  def seed_clients!(operator, advisor)
    specs = [
      { name: "Amara Okafor", email: "amara@#{DEMO_DOMAIN}", source: "website",
        stage: "won", pb_contact: 9501, trip: "Everest Base Camp trek",
        tags: "vip, photographer",
        people: [ [ "Amara Okafor", "amara@#{DEMO_DOMAIN}", "traveler" ] ] },
      { name: "Jonas Weber", email: "jonas@#{DEMO_DOMAIN}", source: "repeat",
        stage: "post_trip", pb_contact: 9502, trip: "Annapurna Circuit trek",
        tags: "alumni", org: operator,
        people: [ [ "Jonas Weber", "jonas@#{DEMO_DOMAIN}", "traveler" ],
                  [ "Lena Weber", "lena@#{DEMO_DOMAIN}", "partner" ] ] },
      { name: "Priya Sharma", email: "priya@#{DEMO_DOMAIN}", source: "referral",
        stage: "won", pb_contact: 9503, trip: "Langtang Valley trek",
        tags: "referral", org: advisor,
        people: [ [ "Priya Sharma", "priya@#{DEMO_DOMAIN}", "traveler" ] ] },
      { name: "Daniel Kim", email: "daniel@#{DEMO_DOMAIN}", source: "google_ads",
        campaign: "ebc-spring-2027", stage: "won", pb_contact: nil,
        trip: "Everest Base Camp trek", tags: "first-timer",
        people: [ [ "Daniel Kim", "daniel@#{DEMO_DOMAIN}", "traveler" ] ] },
      { name: "Sofia Marchetti", email: "sofia@#{DEMO_DOMAIN}", source: "website",
        stage: "won", pb_contact: nil, trip: "Annapurna Circuit trek",
        tags: "honeymoon",
        people: [ [ "Sofia Marchetti", "sofia@#{DEMO_DOMAIN}", "traveler" ],
                  [ "Marco Marchetti", "marco@#{DEMO_DOMAIN}", "partner" ] ] }
    ]
    clients = {}
    specs.each do |spec|
      client = Client.find_or_initialize_by(email: spec[:email])
      fresh = client.new_record?
      client.assign_attributes(
        name: spec[:name], kind: "individual", source: spec[:source],
        campaign_name: spec[:campaign],
        perfectbook_contact_id: spec[:pb_contact],
        referred_by_organization: spec[:org]
      )
      # Reseeds leave an existing record's stage alone.
      client.pipeline_stage = spec[:stage] if fresh
      client.save!
      spec[:people].each do |name, email, role|
        client.people.find_or_create_by!(email: email) do |person|
          person.name = name
          person.role = role
        end
      end
      client.tag_list = spec[:tags]
      client.save!
      clients[spec[:name]] = client
      seed_booking!(client, spec) if spec[:pb_contact]
    end

    # One converted lead, so the lineage ("started as a lead") shows.
    becker_lead = Lead.find_or_initialize_by(email: "tom@#{DEMO_DOMAIN}")
    if becker_lead.new_record?
      becker_lead.assign_attributes(name: "Tom Becker", kind: "individual",
        source: "website_form", status: "new", trip_interest: "Everest Base Camp trek",
        party_size: 2, travel_month: 10, travel_year: 2026)
      becker_lead.save!
    end
    unless becker_lead.converted?
      converted = becker_lead.convert_to_client!
      clients["Tom Becker"] = converted
    else
      clients["Tom Becker"] = becker_lead.converted_client
    end
    clients
  end

  def seed_booking!(client, spec)
    now = Time.current
    ref = case client.name
    when "Amara Okafor" then "SH-2026-0142"
    when "Jonas Weber" then "SH-2026-0098"
    when "Priya Sharma" then "SH-2026-0151"
    end
    booking = PerfectBook::Booking.find_or_initialize_by(perfectbook_id: 9200 + spec[:pb_contact])
    booking.assign_attributes(
      perfectbook_contact_id: spec[:pb_contact], ref: ref,
      trip_name: spec[:trip], status: client.pipeline_stage == "post_trip" ? "completed" : "confirmed",
      start_date: client.pipeline_stage == "post_trip" ? Date.new(2025, 11, 3) : Date.new(2026, 10, 12),
      end_date: client.pipeline_stage == "post_trip" ? Date.new(2025, 11, 18) : Date.new(2026, 10, 25),
      party_size: 2, total_minor: 370_000, paid_minor: client.pipeline_stage == "post_trip" ? 370_000 : 100_000,
      balance_due_minor: client.pipeline_stage == "post_trip" ? 0 : 270_000,
      currency: "USD",
      invoice_badge: client.pipeline_stage == "post_trip" ? "paid" : "partially_paid",
      deep_link: "https://perfectbook.sherpaholidays.com/bookings/#{9200 + spec[:pb_contact]}",
      synced_at: now
    )
    booking.save!
    contact = PerfectBook::Contact.find_or_initialize_by(perfectbook_id: spec[:pb_contact])
    contact.assign_attributes(name: client.name, email: client.email, kind: "customer", synced_at: now)
    contact.save!
  end

  def seed_leads!(advisor)
    specs = [
      { name: "Elena Rossi", email: "elena@#{DEMO_DOMAIN}", source: "meta_ads",
        campaign: "annapurna-autumn", status: "chatting",
        trip: "Annapurna Circuit trek", party: 2, month: 11, year: 2026,
        fit: [ 82, "strong", "Flexible October dates and a party of two on an open departure." ],
        received_days_ago: 3 },
      { name: "Hannah Lindqvist", email: "hannah@#{DEMO_DOMAIN}", source: "google_ads",
        campaign: "ebc-spring-2027", status: "new",
        trip: "Everest Base Camp trek", party: 2, month: 4, year: 2027,
        fit: [ 61, "possible", "Right trip and season, dates still vague." ],
        received_days_ago: 2 },
      { name: "Raj Patel", email: "raj@#{DEMO_DOMAIN}", source: "referral",
        status: "nudged", trip: "Langtang Valley trek", party: 4, month: 3, year: 2027,
        fit: [ 45, "possible", "Family group of four; budget not discussed yet." ],
        org: true, received_days_ago: 9 },
      { name: "James Carter", email: "james@#{DEMO_DOMAIN}", source: "website_form",
        status: "new", trip: "Everest Base Camp trek", party: 1, month: nil, year: nil,
        fit: nil, received_days_ago: 0 }
    ]
    leads = {}
    specs.each do |spec|
      lead = Lead.find_or_initialize_by(email: spec[:email])
      fresh = lead.new_record?
      lead.assign_attributes(
        name: spec[:name], kind: "individual", source: spec[:source],
        campaign_name: spec[:campaign],
        trip_interest: spec[:trip], party_size: spec[:party],
        travel_month: spec[:month], travel_year: spec[:year],
        received_at: spec[:received_days_ago].zero? ? 5.hours.ago : spec[:received_days_ago].days.ago,
        referred_by_organization: spec[:org] ? Organization.find_by!(email: "maya@#{DEMO_DOMAIN}") : nil
      )
      # Never clobber the stage on reruns: sending Hannah's quote moves
      # her to quoted, and reseeds must leave that (and any captain move) alone.
      lead.status = spec[:status] if fresh
      if spec[:fit]
        lead.fit_score, lead.fit_band, lead.fit_reason = spec[:fit]
      end
      lead.save!
      lead.people.find_or_create_by!(email: spec[:email]) do |person|
        person.name = spec[:name]
        person.role = "traveler"
      end
      leads[spec[:name]] = lead
    end
    leads
  end

  def seed_conversations!(clients, leads)
    amara = clients["Amara Okafor"]
    jonas = clients["Jonas Weber"]
    priya = clients["Priya Sharma"]
    elena = leads["Elena Rossi"]
    hannah = leads["Hannah Lindqvist"]
    raj = leads["Raj Patel"]
    james = leads["James Carter"]

    first_reply = Template.find_by(name: "First reply to a new inquiry")
    itinerary = Template.find_by(name: "Itinerary follow-up")
    nudge = Template.find_by(name: "Deposit nudge")

    thread(amara, "Re: Everest Base Camp in October", [
      { dir: "in", from: "amara@#{DEMO_DOMAIN}", days_ago: 2, hours_ago: 0,
        body: "Hi! We are set on the October 12 departure. Can we add an extra night in Namche on the way up? I would rather acclimatize slowly." },
      { dir: "out", to: "amara@#{DEMO_DOMAIN}", days_ago: 2, hours_ago: -4,
        template: itinerary, subject: "Your Everest Base Camp itinerary is ready",
        body: "Hi Amara, your itinerary for October 12 is ready, with the extra Namche night built in. Have a look and tell me what you would change." },
      { dir: "in", from: "amara@#{DEMO_DOMAIN}", days_ago: 0, hours_ago: 3, unread: true,
        body: "Perfect, thank you! One more thing: can we rent boots in Kathmandu, or should we bring our own?" }
    ])
    thread(jonas, "Re: Annapurna, we are home", [
      { dir: "in", from: "jonas@#{DEMO_DOMAIN}", days_ago: 5, hours_ago: 0, read: true,
        body: "Back home in Munich. Thank you for the most beautiful two weeks of our lives. Our guide Pasang was wonderful." },
      { dir: "out", to: "jonas@#{DEMO_DOMAIN}", days_ago: 4, hours_ago: 0,
        subject: "Welcome home",
        body: "Welcome home, Jonas! I am so glad the Circuit treated you well. I passed your words to Pasang already." }
    ])
    thread(priya, "Re: Langtang in March", [
      { dir: "in", from: "priya@#{DEMO_DOMAIN}", days_ago: 6, hours_ago: 0, read: true,
        body: "Maya Gurung suggested I write to you. We are four friends hoping for Langtang in late March. Are there seats left?" },
      { dir: "out", to: "priya@#{DEMO_DOMAIN}", days_ago: 1, hours_ago: 0,
        template: first_reply, subject: "Your Langtang Valley trek — let us plan it together",
        body: "Hi Priya, thank you for writing, and please thank Maya for the introduction. March 21 has seats for all four of you." }
    ])
    thread(elena, "Re: Annapurna in November?", [
      { dir: "in", from: "elena@#{DEMO_DOMAIN}", days_ago: 1, hours_ago: 0, unread: true,
        body: "Ciao! We are two friends from Milan, flexible across November. Is the November 3 departure confirmed to go?" }
    ])
    thread(hannah, "Re: Everest spring 2027", [
      { dir: "in", from: "hannah@#{DEMO_DOMAIN}", days_ago: 3, hours_ago: 0, read: true,
        body: "Hej! My husband and I dream of Everest Base Camp next spring. What does early April look like?" },
      { dir: "out", to: "hannah@#{DEMO_DOMAIN}", days_ago: 2, hours_ago: 0,
        subject: "Everest Base Camp, April 2027",
        body: "Hej Hannah! April 5 is my favorite spring departure: stable weather, and only one seat taken so far." }
    ])
    thread(raj, "Re: Langtang for our family", [
      { dir: "in", from: "raj@#{DEMO_DOMAIN}", days_ago: 9, hours_ago: 0, read: true,
        body: "Hello, we are a family of four (kids 12 and 14). Is Langtang suitable for first-time trekkers?" },
      { dir: "out", to: "raj@#{DEMO_DOMAIN}", days_ago: 8, hours_ago: 0,
        template: nudge, subject: "Still thinking about Langtang?",
        body: "Hi Raj, Langtang is a kind first trek for active kids. Shall I hold four seats on the March departure while you decide?" }
    ])
    thread(james, "Everest inquiry from the website", [
      { dir: "in", from: "james@#{DEMO_DOMAIN}", days_ago: 0, hours_ago: 5, unread: true,
        body: "Hi, I found you through a friend. Solo trekker, hoping for Everest sometime next year. Where do I start?" }
    ])

    [ first_reply, itinerary, nudge ].compact.each do |template|
      2.times { template.record_use! }
    end
  end

  def thread(owner, subject, messages)
    convo = owner.conversations.find_or_create_by!(subject: subject)
    messages.each_with_index do |msg, index|
      key = "demo-#{owner.class.name.downcase}-#{owner.id}-#{index}"
      at = msg[:days_ago].days.ago - msg.fetch(:hours_ago, 0).hours
      if msg[:dir] == "in"
        convo.messages.find_or_create_by!(message_id: "<#{key}@#{DEMO_DOMAIN}>") do |m|
          m.direction = "in"
          m.from_address = msg[:from]
          m.sent_at = at
          m.subject = subject
          m.text_body = msg[:body]
          m.status = "received"
          m.read_at = msg[:unread] ? nil : at + 1.hour
        end
      else
        convo.messages.find_or_create_by!(message_id: "<#{key}@#{DEMO_DOMAIN}>") do |m|
          m.direction = "out"
          m.sent_at = at
          m.subject = msg[:subject] || subject
          m.text_body = msg[:body]
          m.status = "sent"
          m.to_addrs = msg[:to]
          m.template = msg[:template] if msg[:template]
        end
      end
    end
    convo.refresh_counters!
    convo
  end

  def seed_quotes!(clients, leads)
    amara = clients["Amara Okafor"]
    jonas = clients["Jonas Weber"]
    hannah = leads["Hannah Lindqvist"]

    if Quote.where(client_id: amara.id).none?
      quote = Quote.new(client: amara,
        trip_name: "Everest Base Camp trek", departure_label: "October departure",
        departure_start_on: Date.new(2026, 10, 12), departure_end_on: Date.new(2026, 10, 25),
        party_size: 2, deposit_minor: 50_000, valid_until: Date.current + 21,
        notes: "Extra night in Namche included, as requested.",
        included: "Guide, porters, lodges, permits, all ground transport."
      )
      quote.lines.build(description: "Everest Base Camp trek, 14 days", quantity: 2, unit_minor: 185_000, total_minor: 370_000)
      quote.lines.build(description: "Extra night in Namche", quantity: 2, unit_minor: 9_500, total_minor: 19_000)
      quote.save!
      quote.deliver!
    end

    if Quote.where(client_id: jonas.id).none?
      quote = Quote.new(client: jonas,
        trip_name: "Annapurna Circuit trek", departure_label: "November departure",
        departure_start_on: Date.new(2025, 11, 3), departure_end_on: Date.new(2025, 11, 18),
        party_size: 2, deposit_minor: 50_000, valid_until: Date.current + 60,
        notes: "Anniversary trip. Window seats on the drive, please."
      )
      quote.lines.build(description: "Annapurna Circuit trek, 16 days", quantity: 2, unit_minor: 179_000, total_minor: 358_000)
      quote.save!
      quote.deliver!
      quote.accept!
      quote.update_columns(sent_at: 75.days.ago, accepted_at: 70.days.ago, view_count: 3, viewed_at: 71.days.ago)
    end

    if Quote.where(lead_id: hannah.id).none?
      quote = Quote.new(client: nil, lead: hannah,
        trip_name: "Everest Base Camp trek", departure_label: "April departure",
        departure_start_on: Date.new(2027, 4, 5), departure_end_on: Date.new(2027, 4, 18),
        party_size: 2, deposit_minor: 50_000, valid_until: Date.current + 30
      )
      quote.lines.build(description: "Everest Base Camp trek, 14 days", quantity: 2, unit_minor: 189_000, total_minor: 378_000)
      quote.save!
      quote.deliver!
    end
  end

  def seed_tasks!(clients, leads)
    today = Date.current
    specs = [
      [ leads["Raj Patel"], "Nudge Raj about the March seats", today - 1, "follow_up" ],
      [ clients["Amara Okafor"], "Reply to Amara about boot rental", today, "follow_up" ],
      [ leads["Elena Rossi"], "Call Elena about the November departure", today, "call" ],
      [ clients["Priya Sharma"], "Send Priya the Langtang packing list", today + 3, "document" ],
      [ clients["Jonas Weber"], "Ask Jonas for a review", today + 5, "review_ask" ]
    ]
    specs.each do |subject, title, due_on, kind|
      next if subject.tasks.where(title: title).exists?

      subject.tasks.create!(title: title, due_on: due_on, kind: kind, created_by: "captain")
    end
    done = clients["Daniel Kim"].tasks.find_or_initialize_by(title: "Confirm Daniel's deposit receipt")
    done.update!(due_on: today, kind: "payment_nudge", created_by: "captain", done_at: Time.current) if done.new_record?
  end

  def seed_notes!(clients, leads)
    amara = clients["Amara Okafor"]
    unless amara.notes.exists?
      amara.notes.create!(body: "Vegetarian meals, slow pace. Amara photographs; allow extra time at viewpoints.")
    end
    elena = leads["Elena Rossi"]
    unless elena.notes.exists?
      elena.notes.create!(body: "Panda AI scored strong: flexible November dates, party of two, open departure.")
    end
  end

  def seed_sync_states!
    %w[catalog contacts bookings].each do |job|
      PerfectBook::SyncState.record_success!(job)
    end
  end
end
