# Launch template library: the messages the captain sends over and over,
# in his own plain voice. No em dashes, American spelling. Idempotent:
# existing templates (matched by name) are left alone so captain edits
# survive reseeds.
TEMPLATES = [
  {
    name: "First reply to a new inquiry",
    purpose: "first_reply",
    subject: "Planning your {{trip}}",
    body: <<~BODY.strip
      Hi {{first_name}},

      Thank you for reaching out to SherpaHolidays. I would love to help you plan {{trip}}.

      Could you tell me your preferred dates, how many people are coming, and how much hiking you are comfortable with? I will put together an itinerary that fits your group.

      Best,
      {{my_name}}
    BODY
  },
  {
    name: "Itinerary follow-up",
    purpose: "itinerary_follow_up",
    subject: "Your {{trip}} itinerary is ready",
    body: <<~BODY.strip
      Hi {{first_name}},

      Your {{trip}} itinerary for {{departure_dates}} is ready. I planned the days with enough time to acclimatize and stops at the best viewpoints.

      Take a look and let me know what you would like to change. We can adjust anything until it works for you.

      Best,
      {{my_name}}
    BODY
  },
  {
    name: "Deposit nudge",
    purpose: "deposit_nudge",
    subject: "Your {{trip}} seats are on hold",
    body: <<~BODY.strip
      Hi {{first_name}},

      A quick reminder that your {{trip}} seats for {{departure_dates}} are on hold until we receive your deposit of {{deposit_due}}.

      Invoice {{invoice_number}} has the details, and your payment reference is {{payment_reference}}. Once the deposit arrives, your seats are confirmed.

      Best,
      {{my_name}}
    BODY
  },
  {
    name: "Document request",
    purpose: "document_request",
    subject: "Documents needed for your {{trip}}",
    body: <<~BODY.strip
      Hi {{first_name}},

      Before we finalize your {{trip}} booking, please send us what is still missing: {{missing_documents}}.

      A clear phone photo of each is fine. We store them securely in our booking system, not in email threads.

      Best,
      {{my_name}}
    BODY
  },
  {
    name: "Pre-trip briefing",
    purpose: "pre_trip_briefing",
    subject: "Getting ready for your {{trip}}",
    body: <<~BODY.strip
      Hi {{first_name}},

      Your {{trip}} is coming up soon, departing {{departure_dates}}. Pack warm layers and boots you have already broken in.

      Your remaining balance of {{balance_due}} is due before we meet in Kathmandu. I will email you again the week you fly with the meeting point and your guide's name.

      Best,
      {{my_name}}
    BODY
  },
  {
    name: "During-trip check-in",
    purpose: "during_trip_checkin",
    subject: "How is the trip going, {{first_name}}?",
    body: <<~BODY.strip
      Hi {{first_name}},

      I wanted to check in while you are on {{trip}}. I hope everything is going well.

      If anything needs to change, like the pace, your room, or an extra rest day, tell your guide or reply to this email and I will take care of it.

      Best,
      {{my_name}}
    BODY
  },
  {
    name: "Review ask",
    purpose: "review_ask",
    subject: "How was {{trip}}?",
    body: <<~BODY.strip
      Hi {{first_name}},

      Welcome home. I hope the trip was everything you wanted.

      Could you take two minutes to leave a review on Google? It is the main way other travelers find a small family company like ours.

      {{google_review_link}}

      If anything could have gone better, please reply and tell me. I read every message.

      And if a friend is thinking about Nepal, ask them to mention your name when they write to us, or reply with their name.

      Thank you,
      {{my_name}}
    BODY
  },
  {
    name: "Repeat-trip nudge",
    purpose: "repeat_nudge",
    subject: "Thinking about another trip, {{first_name}}?",
    body: <<~BODY.strip
      Hi {{first_name}},

      It has been almost a year since your {{trip}}. I hope you are doing well.

      If you are ready for another trip, tell me what you have in mind and I will put together a plan for you.

      And if a friend is thinking about Nepal, ask them to mention your name when they write to us, or reply with their name.

      Best,
      {{my_name}}
    BODY
  }
].freeze

TEMPLATES.each do |attrs|
  Template.find_or_create_by!(name: attrs[:name]) do |template|
    template.assign_attributes(attrs)
  end
end
