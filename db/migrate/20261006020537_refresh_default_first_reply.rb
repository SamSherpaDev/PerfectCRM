# Update only the untouched default. Captain edits and stored messages stay intact.
class RefreshDefaultFirstReply < ActiveRecord::Migration[8.1]
  class MigrationTemplate < ActiveRecord::Base
    self.table_name = "templates"
  end

  NAME = "First reply to a new inquiry".freeze
  SUBJECT = "Planning your {{trip}}".freeze
  OLD_BODY = <<~BODY.strip.freeze
    Hi {{first_name}},

    Thank you for reaching out to SherpaHolidays. I would love to help you plan {{trip}}.

    Could you tell me your preferred dates, how many people are coming, and how much hiking you are comfortable with? I will put together an itinerary that fits your group.

    Best,
    {{my_name}}
  BODY
  NEW_BODY = <<~BODY.strip.freeze
    Hi {{first_name}},

    Thank you for reaching out to SherpaHolidays. I would love to help you plan your {{trip}} and hear what you are looking forward to most.

    I'm {{my_name}}, and we are a Sherpa family business based in San Jose, California. We started SherpaHolidays in March 2026 with a simple priority: putting our travelers' satisfaction first. We work with our Nepal operator partner to plan trips with personal attention, and I would like to get to know you before suggesting an itinerary.

    Would you be open to a short call? We can talk about your preferred dates, who is coming, how much walking feels comfortable, and any questions about hotels, luggage, or getting around. There is no need to have everything figured out yet.

    Please reply with a couple of times that work for you and your time zone. After we talk, I can put together options that fit your group.

    Best,
    {{my_name}}
  BODY

  def up
    MigrationTemplate.where(name: NAME).find_each do |template|
      changed = MigrationTemplate.where(id: template.id, subject: SUBJECT, body: OLD_BODY)
        .update_all(body: NEW_BODY, updated_at: Time.current)
      if changed.zero?
        say "Skipped first-reply template #{template.id}: subject or body differs from the previous default"
      else
        say "Updated first-reply template #{template.id}"
      end
    end
  end

  def down
    raise ActiveRecord::IrreversibleMigration, "Do not restore the superseded first-reply default"
  end
end
