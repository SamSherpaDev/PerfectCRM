require "test_helper"

class CallLogTextsTest < ActiveSupport::TestCase
  # The owner-approved paired texts from the call-back kit, with its
  # [first name], [trip], [day] and [month] placeholders. Do not reword.
  APPROVED = {
    1 => "Hi [first name], this is Sam at SherpaHolidays. I just tried giving you a quick call about your trip inquiry. When is a good time for us to connect by phone, or is text easier for you?",
    2 => "Hi [first name], it's Sam at SherpaHolidays again about your [trip] inquiry. Would [day] morning or afternoon suit you for a short call? A quick reply here works too.",
    3 => "Hi [first name], Sam at SherpaHolidays. I'll leave the calls here for now. Whenever you're ready to talk about [trip], just reply and we'll call you the same business day.",
    recontact: "Hi [first name], it's Sam at SherpaHolidays. You asked about [trip] back in [month]. Is it still on your list? Happy to talk whenever suits you."
  }.freeze

  test "each text matches the approved wording byte for byte" do
    assert_equal APPROVED.keys, CallLog::TEXTS.keys
    CallLog::TEXTS.each do |key, text|
      kit = text.gsub("{{first_name}}", "[first name]").gsub("{{trip}}", "[trip]").gsub("{{day}}", "[day]").gsub("{{month}}", "[month]")
      assert_equal APPROVED.fetch(key), kit
      assert text.ascii_only?, "Text #{key} should be plain ASCII"
      assert_not_includes text, "—"
      assert_not_includes text, "http"
    end
  end

  test "texts fill the first name, trip, next weekday, and inquiry month" do
    travel_to Time.zone.local(2026, 11, 4, 10, 0) do # Wednesday
      lead = Lead.new(name: "Mira Gurung Shah", trip_interest: "Upper Mustang", trip_title: "Everest", received_at: Time.zone.local(2026, 8, 20))
      assert_equal "Hi Mira, it's Sam at SherpaHolidays again about your Upper Mustang inquiry. Would Thursday morning or afternoon " \
        "suit you for a short call? A quick reply here works too.", CallLog.missed_call_text(lead, 2)
      assert_equal "Hi Mira, Sam at SherpaHolidays. I'll leave the calls here for now. Whenever you're ready to talk about Upper Mustang, " \
        "just reply and we'll call you the same business day.", CallLog.missed_call_text(lead, 3)
      assert_equal "Hi Mira, it's Sam at SherpaHolidays. You asked about Upper Mustang back in August. Is it still on your list? " \
        "Happy to talk whenever suits you.", CallLog.missed_call_text(lead, :recontact)
    end
  end

  test "the day skips the weekend and an inquiry over 11 months old names its year" do
    lead = Lead.new(name: "Mira", trip_title: "Everest", received_at: Time.zone.local(2025, 11, 20))
    { 6 => "Monday", 7 => "Monday", 8 => "Monday", 9 => "Tuesday" }.each do |day, expected|
      travel_to Time.zone.local(2026, 11, day, 21, 0) do # Friday Nov 6 to Monday Nov 9
        assert_includes CallLog.missed_call_text(lead, 2), "Would #{expected} morning"
      end
    end
    travel_to Time.zone.local(2026, 11, 6, 12, 0) do
      assert_includes CallLog.missed_call_text(lead, :recontact), "back in November 2025."
      lead.received_at = Time.zone.local(2026, 1, 5)
      assert_includes CallLog.missed_call_text(lead, :recontact), "back in January."
    end
  end

  test "a nameless lead reads Hi, and a missing or unsure trip falls back per text" do
    travel_to Time.zone.local(2026, 11, 4, 10, 0) do
      nameless = Lead.new(name: " ", trip_interest: "Not sure yet", created_at: Time.current)
      assert_equal "Hi, this is Sam at SherpaHolidays. I just tried giving you a quick call about your trip inquiry. When is a good time " \
        "for us to connect by phone, or is text easier for you?", CallLog.missed_call_text(nameless, 1)
      assert_equal "Hi, it's Sam at SherpaHolidays again about your trip inquiry. Would Thursday morning or afternoon suit you for a " \
        "short call? A quick reply here works too.", CallLog.missed_call_text(nameless, 2)
      assert_equal "Hi, Sam at SherpaHolidays. I'll leave the calls here for now. Whenever you're ready to talk about your trip, just " \
        "reply and we'll call you the same business day.", CallLog.missed_call_text(nameless, 3)
      assert_equal "Hi, it's Sam at SherpaHolidays. You asked about a trip back in November. Is it still on your list? Happy to talk " \
        "whenever suits you.", CallLog.missed_call_text(nameless, :recontact)

      unsure_interest = Lead.new(name: "Ang", trip_interest: "not sure yet", trip_title: "Langtang Valley", created_at: Time.current)
      assert_includes CallLog.missed_call_text(unsure_interest, 3), "talk about Langtang Valley, just reply"
    end
  end
end
