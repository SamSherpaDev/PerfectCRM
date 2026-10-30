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

  test "formats +1 numbers with dashes whatever their separators or country" do
    [ "+14155550134", "+1 415 555 0134", "+1 (415) 555-0134" ].each do |raw|
      [ nil, "US", "Canada", "Nepal" ].each do |country|
        assert_equal "415-555-0134", Leads::Phone.format(raw, country: country), [ raw, country ].inspect
      end
    end
    assert_equal "604-555-1234", Leads::Phone.format("+1 (604) 555-1234", country: "Canada")
  end

  test "formats ten digits and 1 plus ten digits with dashes only under the US parsing default" do
    [ "4155550134", "(415) 555-0134", "415.555.0134", "415 555 0134", "415-555-0134", "14155550134", "1 415 555 0134" ].each do |raw|
      [ nil, "", "US", "usa", "United States" ].each do |country|
        assert_equal "415-555-0134", Leads::Phone.format(raw, country: country), [ raw, country ].inspect
      end
    end
    { "9841234567" => "Nepal", "138 1234 5678" => "China", "604 555 1234" => "Canada",
      "1 415 555 0134" => "Canada", "(415) 555-0134" => "GB" }.each do |raw, country|
      assert_equal raw, Leads::Phone.format(raw, country: country), [ raw, country ].inspect
    end
  end

  test "leaves international, extension, and unparseable numbers unchanged" do
    [ "+9779841234567", "+977 984 123 4567", "+977-1-4445555", "+919876543210", "+442079460958", "020 7946 0958",
      "415-555-0134 ext 2", "+1 415 555 0134 x12", "24155550134", "  ask for Alex at reception  " ].each do |other|
      assert_equal other, Leads::Phone.format(other)
    end

    [ nil, "", "   " ].each do |blank|
      assert_nil Leads::Phone.format(blank)
    end
  end
end
