require "test_helper"

class LeadsQuizPhoneTest < ActiveSupport::TestCase
  test "US and international numbers use libphonenumber validation and canonical E164" do
    [ "4155550134", "1 (415) 555-0134", "+1 415 555 0134" ].each do |raw|
      assert_equal "+14155550134", Leads::Phone.parse_quiz(raw)
    end
    assert_equal "+442079460958", Leads::Phone.parse_quiz("+44 20 7946 0958")
    assert_equal "+442079460958", Leads::Phone.parse_quiz("020 7946 0958", country: "GB")
    assert_equal "+9779841234567", Leads::Phone.parse_quiz("+977 9841234567")
    [ "1234567", "+999123456789", "0000000000", "abc4155550134", "4155550134;123", "+1+4155550134" ].each do |raw|
      assert_nil Leads::Phone.parse_quiz(raw), raw
    end
  end

  test "ordinary inquiry formatting is not tightened by the quiz gate" do
    assert_equal "+1234567", Leads::Phone.normalize("+1234567")
    assert_nil Leads::Phone.parse_quiz("+1234567")
  end
end
