require "test_helper"

class CallLogBookingLineTest < ActiveSupport::TestCase
  URL = "https://calendar.app.google/sherpa-call".freeze
  # The approved Texts 1, 2, 3 and R, filled in for Mira's Everest inquiry of
  # August 20 on Wednesday, November 4 (next weekday Thursday).
  APPROVED = {
    1 => "Hi Mira, this is Sam at SherpaHolidays. I just tried giving you a quick call about your trip inquiry. " \
      "When is a good time for us to connect by phone, or is text easier for you?",
    2 => "Hi Mira, it's Sam at SherpaHolidays again about your Everest inquiry. " \
      "Would Thursday morning or afternoon suit you for a short call? A quick reply here works too.",
    3 => "Hi Mira, Sam at SherpaHolidays. I'll leave the calls here for now. " \
      "Whenever you're ready to talk about Everest, just reply and we'll call you the same business day.",
    recontact: "Hi Mira, it's Sam at SherpaHolidays. You asked about Everest back in August. " \
      "Is it still on your list? Happy to talk whenever suits you."
  }.freeze

  setup { @lead = Lead.new(name: "Mira Gurung", trip_title: "Everest", received_at: Time.zone.local(2026, 8, 20)) }

  test "the booking line is owner-approved plain ASCII" do
    assert_equal "You can also pick a call time here: {{booking_link}}", CallLog::BOOKING_LINE
    assert CallLog::BOOKING_LINE.ascii_only?
    assert_not_includes CallLog::BOOKING_LINE, "—"
  end

  test "without a booking link every text stays exactly the approved text" do
    Setting.current.update!(booking_url: "")
    travel_to Time.zone.local(2026, 11, 4, 10, 0) do
      APPROVED.each { |key, approved| assert_equal approved, CallLog.missed_call_text(@lead, key) }
    end
  end

  test "with a booking link each text ends with exactly one booking line" do
    Setting.current.update!(booking_url: URL)
    travel_to Time.zone.local(2026, 11, 4, 10, 0) do
      APPROVED.each do |key, approved|
        assert_equal "#{approved}\nYou can also pick a call time here: #{URL}", CallLog.missed_call_text(@lead, key)
      end
    end
  end
end
