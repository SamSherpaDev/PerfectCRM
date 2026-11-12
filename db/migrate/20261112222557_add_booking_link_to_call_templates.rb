# Adds the approved call-booking paragraph to the default First reply and
# Itinerary follow-up templates. It only inserts one paragraph at an exact
# anchor line; rows without that anchor, or already carrying the link, are
# left alone and logged. While Settings has no booking link the paragraph is
# left out of every rendered email.
class AddBookingLinkToCallTemplates < ActiveRecord::Migration[8.1]
  class MigrationTemplate < ActiveRecord::Base
    self.table_name = "templates"
  end

  PLACEHOLDER = "{{booking_link}}".freeze
  FIRST_REPLY_NAME = "First reply to a new inquiry".freeze
  FIRST_REPLY_ANCHOR = "Please reply with a couple of times that work for you and your time zone. " \
    "After we talk, I can put together options that fit your group.".freeze
  FIRST_REPLY_LINE = "If it is easier, you can also pick a call time here: {{booking_link}}".freeze
  FOLLOW_UP_NAME = "Itinerary follow-up".freeze
  FOLLOW_UP_ANCHOR = "Best,".freeze
  FOLLOW_UP_LINE = "If a call would help, you can pick a time here: {{booking_link}}".freeze

  def up
    insert(FIRST_REPLY_NAME, "first-reply") { |body| insert_after(body, FIRST_REPLY_ANCHOR, FIRST_REPLY_LINE) }
    insert(FOLLOW_UP_NAME, "itinerary follow-up") { |body| insert_before(body, FOLLOW_UP_ANCHOR, FOLLOW_UP_LINE) }
  end

  def down
    remove(FIRST_REPLY_NAME) { |newline| "#{newline}#{newline}#{FIRST_REPLY_LINE}" }
    remove(FOLLOW_UP_NAME) { |newline| "#{FOLLOW_UP_LINE}#{newline}#{newline}" }
  end

  private

  def insert(name, label)
    MigrationTemplate.where(name: name).find_each do |template|
      body = template.body.to_s
      updated = yield(body) unless body.include?(PLACEHOLDER)
      if updated
        template.update_columns(body: updated, updated_at: Time.current)
        say "Updated #{label} template #{template.id}"
      else
        say "Skipped #{label} template #{template.id}: it already has the booking link or its anchor line is edited"
      end
    end
  end

  def remove(name)
    MigrationTemplate.where(name: name).find_each do |template|
      body = template.body.to_s
      text = yield(newline_in(body))
      template.update_columns(body: body.sub(text, ""), updated_at: Time.current) if body.scan(text).one?
    end
  end

  # The paragraph sits next to an anchor that is its own line, found exactly once.
  def insert_after(body, anchor, line)
    pattern = anchor_line(anchor)
    newline = newline_in(body)
    body.sub(pattern) { "#{anchor}#{newline}#{newline}#{line}" } if body.scan(pattern).one?
  end

  def insert_before(body, anchor, line)
    pattern = anchor_line(anchor)
    newline = newline_in(body)
    body.sub(pattern) { "#{line}#{newline}#{newline}#{anchor}" } if body.scan(pattern).one?
  end

  def anchor_line(anchor)
    /^#{Regexp.escape(anchor)}(?=\r?$)/
  end

  def newline_in(body)
    body.include?("\r\n") ? "\r\n" : "\n"
  end
end
