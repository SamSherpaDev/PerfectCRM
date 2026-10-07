require "test_helper"

class LeadPhoneTest < ActiveSupport::TestCase
  test "US is the parsing default, not an inferred country on the record" do
    [ nil, "", "US", "USA", "United States", "United States of America" ].each do |country|
      assert_equal "+14155550134", Leads::Phone.normalize("(415) 555-0134", country: country)
    end
    assert_nil Leads::Phone.normalize("4155550134", country: "GB")
    assert_equal "+442079460958", Leads::Phone.normalize("+44 20 7946 0958", country: "US")
  end

  test "unparseable input is not guessed or stripped into a different number" do
    [ nil, "", "call reception", "4155550134 ext 2", "12345", "24155550134", "+1234567890123456", "+0000000000" ].each do |raw|
      assert_nil Leads::Phone.normalize(raw)
    end
  end
end
