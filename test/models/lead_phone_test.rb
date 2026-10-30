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

  test "formats US and Canada +1 or bare 10-digit numbers with dashes and leaves other numbers unchanged" do
    assert_equal "609-781-0024", Leads::Phone.format("+16097810024")
    assert_equal "609-781-0024", Leads::Phone.format("6097810024")
    assert_equal "416-555-0199", Leads::Phone.format("+14165550199")

    [ "+9779841234567", "+977-1-4445555", "+919876543210", "+442079460958", "020 7946 0958", "  ask for Alex at reception  " ].each do |other|
      assert_equal other, Leads::Phone.format(other)
    end

    [ nil, "", "   " ].each do |blank|
      assert_nil Leads::Phone.format(blank)
    end
  end
end
