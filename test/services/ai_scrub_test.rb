require "test_helper"

class AiScrubTest < ActiveSupport::TestCase
  test "redacts long digit runs both ways" do
    assert_equal "[redacted]", Ai::Scrub.scrub("passport 123456789")
    assert_equal "card [redacted]", Ai::Scrub.scrub("card 4111 1111 1111 1111")
    assert Ai::Scrub.sensitive?("passport X1234567")
    assert_not Ai::Scrub.sensitive?("Namaste, we want Everest in May.")
  end

  test "redacts dates of birth near a label" do
    assert_equal "[redacted]", Ai::Scrub.scrub("DOB: 1990/05/14")
    assert_equal "hello there", Ai::Scrub.scrub("hello there")
  end

  test "output filter strips echoed numbers" do
    dirty = "Your passport 123456789 is noted"
    assert_equal "Your [redacted] is noted", Ai::Scrub.scrub(dirty)
  end
  test "redacts multiline identity labels with LF and CRLF" do
    [ "\n", "\r\n", "\n  ", "\n\n" ].each do |separator|
      [ "Date of birth:#{separator}14 May 1990", "DOB:#{separator}1990/05/14",
        "Passport:#{separator}X1234567" ].each do |identity|
        assert_equal "[redacted]", Ai::Scrub.scrub(identity)
        assert_equal "[redacted]", Ai::Scrub.scrub(Ai::Scrub.scrub(identity))
      end
    end
  end
end
