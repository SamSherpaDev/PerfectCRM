# Launch template library: the messages the captain sends over and over,
# in his voice — warm, personal, premium, sentence case. Idempotent: existing
# templates (matched by name) are left alone so captain edits survive reseeds.
TEMPLATES = [
  {
    name: "First reply to a new inquiry",
    purpose: "first_reply",
    subject: "Your {{trip}} — let us plan it together",
    body: <<~BODY.strip
      Hi {{first_name}},

      Thank you for writing to Sherpa Holidays. {{trip}} is a wonderful choice, and I would love to help you plan it well.

      Tell me a little about your dates, your group, and how you like to walk, and I will put together an itinerary that fits you.

      Warmly,
      {{my_name}}
    BODY
  },
  {
    name: "Itinerary follow-up",
    purpose: "itinerary_follow_up",
    subject: "Your {{trip}} itinerary is ready",
    body: <<~BODY.strip
      Hi {{first_name}},

      Your {{trip}} itinerary for {{departure_dates}} is ready. I have shaped the days around good acclimatization and the views you should not miss.

      Have a look and tell me what you would change. Nothing is fixed until it feels right to you.

      Warmly,
      {{my_name}}
    BODY
  },
  {
    name: "Deposit nudge",
    purpose: "deposit_nudge",
    subject: "Holding your {{trip}} seats with {{deposit_due}}",
    body: <<~BODY.strip
      Hi {{first_name}},

      A gentle note that your {{trip}} seats for {{departure_dates}} are held until your deposit of {{deposit_due}} arrives.

      Invoice {{invoice_number}} has the details, and your payment reference is {{payment_reference}}. Once the deposit lands, everything else is confirmed.

      Warmly,
      {{my_name}}
    BODY
  },
  {
    name: "Document request",
    purpose: "document_request",
    subject: "Two small things before your {{trip}}",
    body: <<~BODY.strip
      Hi {{first_name}},

      Before we finalize your {{trip}} booking, please send over what is still missing: {{missing_documents}}.

      A clear phone photo of each is plenty. Everything is stored securely with our bookkeeping, never over email threads.

      Warmly,
      {{my_name}}
    BODY
  },
  {
    name: "Pre-trip briefing",
    purpose: "pre_trip_briefing",
    subject: "Before you fly — your {{trip}} briefing",
    body: <<~BODY.strip
      Hi {{first_name}},

      Your {{trip}} is almost here, departing {{departure_dates}}. Pack warm layers, broken-in boots, and a sense of unhurried mornings.

      Your remaining balance of {{balance_due}} is due before we meet in Kathmandu. I will write again the week you fly with our meeting point and your guide's name.

      Warmly,
      {{my_name}}
    BODY
  },
  {
    name: "During-trip check-in",
    purpose: "during_trip_checkin",
    subject: "Enjoying the trail, {{first_name}}?",
    body: <<~BODY.strip
      Hi {{first_name}},

      Just checking in while you are out on {{trip}}. I hope the legs feel strong and the mountains are showing themselves.

      If anything needs adjusting — pace, rooms, an extra rest day — tell your guide or reply here and I will sort it.

      Warmly,
      {{my_name}}
    BODY
  },
  {
    name: "Review ask",
    purpose: "review_ask",
    subject: "Welcome home — how was {{trip}}?",
    body: <<~BODY.strip
      Hi {{first_name}},

      Welcome home from {{trip}}. I hope you are still carrying a little of the mountain quiet with you.

      If you have a minute, an honest review in your own words would mean a lot to our small family company. Just reply here and I will treasure it.

      Warmly,
      {{my_name}}
    BODY
  },
  {
    name: "Repeat-trip nudge",
    purpose: "repeat_nudge",
    subject: "{{first_name}}, another trail is calling",
    body: <<~BODY.strip
      Hi {{first_name}},

      It has been a season since your {{trip}}, and I keep thinking how well you walked it. The {{trip}} departures for {{departure_dates}} are shaping up beautifully.

      If your feet are restless, tell me where your mind wanders and I will plan something worthy of it.

      Warmly,
      {{my_name}}
    BODY
  }
].freeze

TEMPLATES.each do |attrs|
  Template.find_or_create_by!(name: attrs[:name]) do |template|
    template.assign_attributes(attrs)
  end
end
