require "test_helper"
require_relative "../../db/migrate/20261006020537_refresh_default_first_reply"

class FirstReplyMigrationTest < ActiveSupport::TestCase
  setup do
    @template = Template.create!(name: RefreshDefaultFirstReply::NAME, purpose: :first_reply,
      subject: RefreshDefaultFirstReply::SUBJECT, body: RefreshDefaultFirstReply::OLD_BODY)
  end

  test "exact previous default updates and repeated runs leave the row alone" do
    migrate
    assert_equal RefreshDefaultFirstReply::SUBJECT, @template.reload.subject
    assert_equal RefreshDefaultFirstReply::NEW_BODY, @template.body
    updated_at = @template.updated_at
    migrate
    assert_equal updated_at, @template.reload.updated_at
  end

  test "body edits including whitespace are preserved and logged" do
    [ "My personal greeting", "#{RefreshDefaultFirstReply::OLD_BODY}\n" ].each do |body|
      @template.update!(body: body)
      output, = capture_io { RefreshDefaultFirstReply.new.migrate(:up) }
      assert_equal body, @template.reload.body
      assert_equal RefreshDefaultFirstReply::SUBJECT, @template.subject
      assert_includes output, "Skipped first-reply template #{@template.id}"
    end
  end

  test "subject edits are preserved and logged even when the body matches" do
    @template.update!(subject: "A personal welcome")
    output, = capture_io { RefreshDefaultFirstReply.new.migrate(:up) }
    assert_equal "A personal welcome", @template.reload.subject
    assert_equal RefreshDefaultFirstReply::OLD_BODY, @template.body
    assert_includes output, "Skipped first-reply template #{@template.id}"
  end

  test "another template with identical wording is outside the migration" do
    @template.update!(name: "My inquiry reply")
    migrate
    assert_equal RefreshDefaultFirstReply::OLD_BODY, @template.reload.body
  end

  test "seed matches migration and is warm call-first copy without prices or unverified claims" do
    @template.destroy!
    Object.send(:remove_const, :TEMPLATES) if Object.const_defined?(:TEMPLATES)
    load Rails.root.join("db/seeds/templates.rb")
    seeded = Template.find_by!(name: RefreshDefaultFirstReply::NAME)
    assert_equal RefreshDefaultFirstReply::SUBJECT, seeded.subject
    assert_equal RefreshDefaultFirstReply::NEW_BODY, seeded.body
    assert_includes seeded.body, "Sherpa family business"
    assert_includes seeded.body, "March 2026"
    assert_includes seeded.body, "Would you be open to a short call?"
    assert_includes seeded.body, "After we talk"
    assert_includes 120..200, seeded.body.split.size
    assert_no_match(/—|\$|prices|packages|licensed|guaranteed departures/i, seeded.body)
  end

  private

  def migrate
    ActiveRecord::Migration.suppress_messages { RefreshDefaultFirstReply.new.migrate(:up) }
  end
end
