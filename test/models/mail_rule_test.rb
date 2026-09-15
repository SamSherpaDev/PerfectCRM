require "test_helper"

class MailRuleTest < ActiveSupport::TestCase
  test "keeps mail where info@ appears in any delivered header" do
    assert Mail.keeps?({ "from" => [ "info@sherpaholidays.com" ], "to" => [ "a@test" ] })
    assert Mail.keeps?({ "from" => [ "a@test" ], "to" => [ "info@sherpaholidays.com" ] })
    assert Mail.keeps?({ "from" => [ "a@test" ], "to" => [ "b@test" ], "cc" => [ "info@sherpaholidays.com" ] })
    assert Mail.keeps?({ "from" => [ "a@test" ], "to" => [ "b@test" ], "delivered-to" => [ "info@sherpaholidays.com" ] })
    assert Mail.keeps?({ "from" => [ "a@test" ], "to" => [ "b@test" ], "x-original-to" => [ "info@sherpaholidays.com" ] })
  end

  test "skips personal mail with no mailbox trace" do
    assert_not Mail.keeps?({ "from" => [ "friend@gmail.com" ], "to" => [ "captain@gmail.com" ] })
    assert_not Mail.keeps?({ "from" => [ "spam@test" ], "to" => [ "other@test" ] })
  end

  test "direction is out only when the sender is the mailbox" do
    assert_equal "out", Mail.direction_for([ "info@sherpaholidays.com" ])
    assert_equal "out", Mail.direction_for([ "INFO@sherpaholidays.com" ])
    assert_equal "in", Mail.direction_for([ "client@example.com" ])
  end

  test "respects configured aliases" do
    old = ENV["MAILBOX_ALIASES"]
    ENV["MAILBOX_ALIASES"] = "hello@sherpaholidays.com"
    assert Mail.keeps?({ "from" => [ "a@test" ], "to" => [ "hello@sherpaholidays.com" ] })
  ensure
    ENV["MAILBOX_ALIASES"] = old
  end
end
