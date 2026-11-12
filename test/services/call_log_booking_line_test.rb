require "test_helper"

class CallLogBookingLineTest < ActiveSupport::TestCase
  URL = "https://calendar.app.google/sherpa-call".freeze
  KEYS = [ 1, 2, 3, :recontact ].freeze

  setup { @lead = Lead.new(name: "Mira Gurung", trip_title: "Everest", received_at: Time.zone.local(2026, 8, 20)) }

  test "the booking line is owner-approved plain ASCII" do
    assert_equal "You can also pick a call time here: {{booking_link}}", CallLog::BOOKING_LINE
    assert CallLog::BOOKING_LINE.ascii_only?
    assert_not_includes CallLog::BOOKING_LINE, "—"
  end

  test "without a booking link every text stays exactly the approved text" do
    Setting.current.update!(booking_url: "")
    travel_to Time.zone.local(2026, 11, 4, 10, 0) do
      KEYS.each do |key|
        text = CallLog.missed_call_text(@lead, key)
        assert_not_includes text, "\n"
        assert_not_includes text, "pick a call time"
      end
    end
  end

  test "with a booking link each text ends with exactly one booking line" do
    travel_to Time.zone.local(2026, 11, 4, 10, 0) do
      plain = KEYS.to_h { |key| [ key, CallLog.missed_call_text(@lead, key) ] }
      Setting.current.update!(booking_url: URL)
      KEYS.each do |key|
        text = CallLog.missed_call_text(@lead, key)
        assert_equal "#{plain.fetch(key)}\nYou can also pick a call time here: #{URL}", text
        assert_equal 1, text.scan("pick a call time").size
      end
    end
  end
end
