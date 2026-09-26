# Moves the launch templates to the plain wording in db/seeds/templates.rb.
# A row changes only while its name, subject, and body still match the old
# default exactly, so any template the captain edited is left alone.
class RefreshDefaultTemplateWording < ActiveRecord::Migration[8.1]
  class MigrationTemplate < ActiveRecord::Base
    self.table_name = "templates"
  end

  # [name, old subject, old body, new subject, new body]
  CHANGES = [
    [
      "First reply to a new inquiry",
      "Your {{trip}} \u2014 let us plan it together",
      <<~OLD.strip,
        Hi {{first_name}},

        Thank you for writing to Sherpa Holidays. {{trip}} is a wonderful choice, and I would love to help you plan it well.

        Tell me a little about your dates, your group, and how you like to walk, and I will put together an itinerary that fits you.

        Warmly,
        {{my_name}}
      OLD
      "Planning your {{trip}}",
      <<~NEW.strip
        Hi {{first_name}},

        Thank you for reaching out to SherpaHolidays. I would love to help you plan {{trip}}.

        Could you tell me your preferred dates, how many people are coming, and how much hiking you are comfortable with? I will put together an itinerary that fits your group.

        Best,
        {{my_name}}
      NEW
    ],
    [
      "Itinerary follow-up",
      "Your {{trip}} itinerary is ready",
      <<~OLD.strip,
        Hi {{first_name}},

        Your {{trip}} itinerary for {{departure_dates}} is ready. I have shaped the days around good acclimatization and the views you should not miss.

        Have a look and tell me what you would change. Nothing is fixed until it feels right to you.

        Warmly,
        {{my_name}}
      OLD
      "Your {{trip}} itinerary is ready",
      <<~NEW.strip
        Hi {{first_name}},

        Your {{trip}} itinerary for {{departure_dates}} is ready. I planned the days with enough time to acclimatize and stops at the best viewpoints.

        Take a look and let me know what you would like to change. We can adjust anything until it works for you.

        Best,
        {{my_name}}
      NEW
    ],
    [
      "Deposit nudge",
      "Holding your {{trip}} seats with {{deposit_due}}",
      <<~OLD.strip,
        Hi {{first_name}},

        A gentle note that your {{trip}} seats for {{departure_dates}} are held until your deposit of {{deposit_due}} arrives.

        Invoice {{invoice_number}} has the details, and your payment reference is {{payment_reference}}. Once the deposit lands, everything else is confirmed.

        Warmly,
        {{my_name}}
      OLD
      "Your {{trip}} seats are on hold",
      <<~NEW.strip
        Hi {{first_name}},

        A quick reminder that your {{trip}} seats for {{departure_dates}} are on hold until we receive your deposit of {{deposit_due}}.

        Invoice {{invoice_number}} has the details, and your payment reference is {{payment_reference}}. Once the deposit arrives, your seats are confirmed.

        Best,
        {{my_name}}
      NEW
    ],
    [
      "Document request",
      "Two small things before your {{trip}}",
      <<~OLD.strip,
        Hi {{first_name}},

        Before we finalize your {{trip}} booking, please send over what is still missing: {{missing_documents}}.

        A clear phone photo of each is plenty. Everything is stored securely with our bookkeeping, never over email threads.

        Warmly,
        {{my_name}}
      OLD
      "Documents needed for your {{trip}}",
      <<~NEW.strip
        Hi {{first_name}},

        Before we finalize your {{trip}} booking, please send us what is still missing: {{missing_documents}}.

        A clear phone photo of each is fine. We store them securely in our booking system, not in email threads.

        Best,
        {{my_name}}
      NEW
    ],
    [
      "Pre-trip briefing",
      "Before you fly \u2014 your {{trip}} briefing",
      <<~OLD.strip,
        Hi {{first_name}},

        Your {{trip}} is almost here, departing {{departure_dates}}. Pack warm layers, broken-in boots, and a sense of unhurried mornings.

        Your remaining balance of {{balance_due}} is due before we meet in Kathmandu. I will write again the week you fly with our meeting point and your guide's name.

        Warmly,
        {{my_name}}
      OLD
      "Getting ready for your {{trip}}",
      <<~NEW.strip
        Hi {{first_name}},

        Your {{trip}} is coming up soon, departing {{departure_dates}}. Pack warm layers and boots you have already broken in.

        Your remaining balance of {{balance_due}} is due before we meet in Kathmandu. I will email you again the week you fly with the meeting point and your guide's name.

        Best,
        {{my_name}}
      NEW
    ],
    [
      "During-trip check-in",
      "Enjoying the trail, {{first_name}}?",
      <<~OLD.strip,
        Hi {{first_name}},

        Just checking in while you are out on {{trip}}. I hope the legs feel strong and the mountains are showing themselves.

        If anything needs adjusting \u2014 pace, rooms, an extra rest day \u2014 tell your guide or reply here and I will sort it.

        Warmly,
        {{my_name}}
      OLD
      "How is the trip going, {{first_name}}?",
      <<~NEW.strip
        Hi {{first_name}},

        I wanted to check in while you are on {{trip}}. I hope everything is going well.

        If anything needs to change, like the pace, your room, or an extra rest day, tell your guide or reply to this email and I will take care of it.

        Best,
        {{my_name}}
      NEW
    ],
    [
      "Review ask",
      "Welcome home \u2014 how was {{trip}}?",
      <<~OLD.strip,
        Hi {{first_name}},

        Welcome home from {{trip}}. I hope you are still carrying a little of the mountain quiet with you.

        If you have a minute, an honest review in your own words would mean a lot to our small family company. Just reply here and I will treasure it.

        Warmly,
        {{my_name}}
      OLD
      "How was {{trip}}?",
      <<~NEW.strip
        Hi {{first_name}},

        Welcome home. I hope the trip was everything you wanted.

        Could you take two minutes to leave a review on Google? It is the main way other travelers find a small family company like ours.

        {{google_review_link}}

        If anything could have gone better, please reply and tell me. I read every message.

        And if a friend is thinking about Nepal, ask them to mention your name when they write to us, or reply with their name.

        Thank you,
        {{my_name}}
      NEW
    ],
    [
      "Repeat-trip nudge",
      "{{first_name}}, another trail is calling",
      <<~OLD.strip,
        Hi {{first_name}},

        It has been a season since your {{trip}}, and I keep thinking how well you walked it. The {{trip}} departures for {{departure_dates}} are shaping up beautifully.

        If your feet are restless, tell me where your mind wanders and I will plan something worthy of it.

        Warmly,
        {{my_name}}
      OLD
      "Thinking about another trip, {{first_name}}?",
      <<~NEW.strip
        Hi {{first_name}},

        It has been almost a year since your {{trip}}. I hope you are doing well.

        If you are ready for another trip, tell me what you have in mind and I will put together a plan for you.

        And if a friend is thinking about Nepal, ask them to mention your name when they write to us, or reply with their name.

        Best,
        {{my_name}}
      NEW
    ]
  ].freeze

  def up
    CHANGES.each do |name, old_subject, old_body, new_subject, new_body|
      swap(name, old_subject, old_body, new_subject, new_body)
    end
  end

  def down
    CHANGES.each do |name, old_subject, old_body, new_subject, new_body|
      swap(name, new_subject, new_body, old_subject, old_body)
    end
  end

  private

  def swap(name, from_subject, from_body, to_subject, to_body)
    MigrationTemplate.where(name: name, subject: from_subject, body: from_body)
      .update_all(subject: to_subject, body: to_body, updated_at: Time.current)
  end
end
