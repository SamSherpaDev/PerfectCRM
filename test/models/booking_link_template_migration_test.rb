require "test_helper"
require_relative "../../db/migrate/20261112222557_add_booking_link_to_call_templates"

class BookingLinkTemplateMigrationTest < ActiveSupport::TestCase
  MIGRATION = AddBookingLinkToCallTemplates
  FIRST_REPLY = <<~BODY.strip
    Hi {{first_name}},

    Would you be open to a short call?

    #{MIGRATION::FIRST_REPLY_ANCHOR}

    Best,
    {{my_name}}
  BODY
  FOLLOW_UP = <<~BODY.strip
    Hi {{first_name}},

    Your {{trip}} itinerary is ready.

    Best,
    {{my_name}}
  BODY

  setup do
    @first_reply = Template.create!(name: MIGRATION::FIRST_REPLY_NAME, purpose: :first_reply, subject: "Planning", body: FIRST_REPLY)
    @follow_up = Template.create!(name: MIGRATION::FOLLOW_UP_NAME, purpose: :itinerary_follow_up, subject: "Ready", body: FOLLOW_UP)
  end

  test "inserts each paragraph once at its anchor and repeated runs leave the rows alone" do
    migrate
    assert_equal FIRST_REPLY.sub(MIGRATION::FIRST_REPLY_ANCHOR,
      "#{MIGRATION::FIRST_REPLY_ANCHOR}\n\nIf it is easier, you can also pick a call time here: {{booking_link}}"), @first_reply.reload.body
    assert_equal FOLLOW_UP.sub("\nBest,", "\nIf a call would help, you can pick a time here: {{booking_link}}\n\nBest,"), @follow_up.reload.body
    stamps = [ @first_reply.updated_at, @follow_up.updated_at ]
    migrate
    assert_equal stamps, [ @first_reply.reload.updated_at, @follow_up.reload.updated_at ]
    assert_equal 1, @first_reply.body.scan("{{booking_link}}").size
    assert_equal 1, @follow_up.body.scan("{{booking_link}}").size
  end

  test "rows saved from the editor with CRLF line endings get the paragraph in CRLF and down removes it" do
    first_reply_crlf = FIRST_REPLY.gsub("\n", "\r\n")
    follow_up_crlf = FOLLOW_UP.gsub("\n", "\r\n")
    @first_reply.update!(body: first_reply_crlf)
    @follow_up.update!(body: follow_up_crlf)
    migrate
    assert_equal first_reply_crlf.sub("group.\r\n\r\nBest,",
      "group.\r\n\r\nIf it is easier, you can also pick a call time here: {{booking_link}}\r\n\r\nBest,"), @first_reply.reload.body
    assert_equal follow_up_crlf.sub("ready.\r\n\r\nBest,",
      "ready.\r\n\r\nIf a call would help, you can pick a time here: {{booking_link}}\r\n\r\nBest,"), @follow_up.reload.body
    assert_equal ::TemplateRenderer.render(first_reply_crlf, first_name: "Mira", my_name: "Sam"),
      ::TemplateRenderer.render(@first_reply.body, first_name: "Mira", my_name: "Sam")
    ActiveRecord::Migration.suppress_messages { MIGRATION.new.migrate(:down) }
    assert_equal [ first_reply_crlf, follow_up_crlf ], [ @first_reply.reload.body, @follow_up.reload.body ]
  end

  test "rows without the exact anchor line are preserved and logged" do
    @first_reply.update!(body: FIRST_REPLY.sub("your time zone.", "your timezone."))
    @follow_up.update!(body: FOLLOW_UP.sub("Best,", "Warmly,"))
    edited = [ @first_reply.body, @follow_up.body ]
    output, = capture_io { MIGRATION.new.migrate(:up) }
    assert_equal edited, [ @first_reply.reload.body, @follow_up.reload.body ]
    assert_includes output, "Skipped first-reply template #{@first_reply.id}"
    assert_includes output, "Skipped itinerary follow-up template #{@follow_up.id}"
  end

  test "a row that already has a booking link is left alone" do
    body = "#{FIRST_REPLY}\n\nBook here: {{booking_link}}"
    @first_reply.update!(body: body)
    output, = capture_io { MIGRATION.new.migrate(:up) }
    assert_equal body, @first_reply.reload.body
    assert_includes output, "Skipped first-reply template #{@first_reply.id}"
  end

  test "another template with the same anchor is outside the migration" do
    @first_reply.update!(name: "My inquiry reply")
    migrate
    assert_equal FIRST_REPLY, @first_reply.reload.body
  end

  test "down removes only the inserted paragraphs" do
    migrate
    ActiveRecord::Migration.suppress_messages { MIGRATION.new.migrate(:down) }
    assert_equal [ FIRST_REPLY, FOLLOW_UP ], [ @first_reply.reload.body, @follow_up.reload.body ]
  end

  test "the rendered email is unchanged while Settings has no booking link and carries it once set" do
    migrate
    assert_equal ::TemplateRenderer.render(FIRST_REPLY, first_name: "Mira", my_name: "Sam"),
      ::TemplateRenderer.render(@first_reply.reload.body, first_name: "Mira", my_name: "Sam")
    assert_equal ::TemplateRenderer.render(FOLLOW_UP, first_name: "Mira", my_name: "Sam", trip: "Everest"),
      ::TemplateRenderer.render(@follow_up.reload.body, first_name: "Mira", my_name: "Sam", trip: "Everest")
    linked = ::TemplateRenderer.render(@first_reply.body, first_name: "Mira", my_name: "Sam", booking_link: "https://calendar.app.google/x")
    assert_includes linked, "group.\n\nIf it is easier, you can also pick a call time here: https://calendar.app.google/x\n\nBest,"
  end

  test "the seeded templates carry the same approved paragraphs" do
    Template.delete_all
    Object.send(:remove_const, :TEMPLATES) if Object.const_defined?(:TEMPLATES)
    load Rails.root.join("db/seeds/templates.rb")
    first_reply = Template.find_by!(name: MIGRATION::FIRST_REPLY_NAME).body
    assert_includes first_reply, "#{MIGRATION::FIRST_REPLY_ANCHOR}\n\n#{MIGRATION::FIRST_REPLY_LINE}\n\nBest,"
    assert_includes Template.find_by!(name: MIGRATION::FOLLOW_UP_NAME).body, "#{MIGRATION::FOLLOW_UP_LINE}\n\nBest,\n{{my_name}}"
    [ MIGRATION::FIRST_REPLY_LINE, MIGRATION::FOLLOW_UP_LINE ].each { |line| assert line.ascii_only? }
  end

  private

  def migrate
    ActiveRecord::Migration.suppress_messages { MIGRATION.new.migrate(:up) }
  end
end
