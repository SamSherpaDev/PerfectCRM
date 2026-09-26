require "test_helper"

class WeeklyReportSummaryTest < ActiveSupport::TestCase
  WEEK = Date.new(2026, 9, 14)

  setup do
    travel_to Time.zone.local(2026, 9, 21, 7)
  end

  def inquiry(name, source: "google_ads", campaign: nil, at: Time.zone.local(2026, 9, 15, 10), **attrs)
    Lead.create!(name: name, source: source, campaign_name: campaign, received_at: at, **attrs)
  end

  def move(lead, to, at:, actor: :captain)
    travel_to(at) { Leads::Transition.call(lead, to: to, actor: actor) }
  end

  def row(summary, label)
    summary.rows.find { |candidate| candidate.label == label }
  end

  test "last complete week is the Monday to Sunday before today" do
    assert_equal WEEK, WeeklyReport::Summary.last_complete_week
    assert_equal WEEK, WeeklyReport::Summary.last_complete_week(today: Date.new(2026, 9, 27))
    assert_equal "Sep 14-20", WeeklyReport::Summary.week_label(WEEK)
    assert_equal "Sep 28-Oct 4", WeeklyReport::Summary.week_label(Date.new(2026, 9, 30))
  end

  test "counts inquiries and qualified leads by channel and campaign with cost per inquiry" do
    strong = inquiry("Strong", campaign: "ebc_search", fit_band: "strong")
    inquiry("Weak", campaign: "ebc_search", fit_band: "weak")
    auto = inquiry("Auto chat", campaign: "ebc_search", fit_band: "possible")
    inquiry("Meta ask", source: "meta_ads", campaign: "social")
    inquiry("Form", source: "website_form")
    inquiry("Before the week", at: Time.zone.local(2026, 9, 13, 23))
    inquiry("Archived test").archive!
    inquiry("Spam", tag_list: Lead::SUSPECTED_SPAM_TAG)
    move(strong, "chatting", at: Time.zone.local(2026, 9, 16, 9))
    move(auto, "chatting", at: Time.zone.local(2026, 9, 16, 9), actor: :automation)
    AdSpend.record!(week_start: WEEK, source: "google_ads", campaign_name: "ebc_search", amount_dollars: "126")
    AdSpend.record!(week_start: WEEK, source: "meta_ads", campaign_name: "social", amount_dollars: "140")

    summary = WeeklyReport::Summary.new(week_start: WEEK)
    google = row(summary, "Google ebc_search")
    assert_equal [ 12_600, 3, 1 ], [ google.spend_minor, google.inquiries, google.qualified ]
    assert_equal 4_200, google.cost_per_inquiry
    assert_equal 12_600, google.cost_per_qualified
    meta = row(summary, "Meta social")
    assert_equal [ 14_000, 1, 0 ], [ meta.spend_minor, meta.inquiries, meta.qualified ]
    assert_nil meta.cost_per_qualified
    assert_equal 1, row(summary, "Website form").inquiries
    assert_equal [ 5, 1, 26_600 ], [ summary.total.inquiries, summary.total.qualified, summary.total.spend_minor ]
    assert_equal [ 4, 6_650 ], [ summary.paid_total.inquiries, summary.paid_total.cost_per_inquiry ]
    assert_equal "5 inquiries, 1 qualified, 0 booked", summary.headline
    assert summary.spend_entered?
    assert_equal 1, summary.suspected_spam_count
  end

  test "campaign identity is exact and incomplete spend makes aggregate costs unknown" do
    inquiry("One", campaign: "EBC")
    inquiry("Two", campaign: "ebc")
    inquiry("Meta", source: "meta_ads", campaign: "social")
    AdSpend.record!(week_start: WEEK, source: "google_ads", campaign_name: "EBC", amount_dollars: "100")
    AdSpend.record!(week_start: WEEK, source: "google_ads", campaign_name: "ebc", amount_dollars: "120")

    summary = WeeklyReport::Summary.new(week_start: WEEK)
    assert_equal 10_000, row(summary, "Google EBC").spend_minor
    assert_equal 12_000, row(summary, "Google ebc").spend_minor
    assert_equal 1, row(summary, "Google EBC").inquiries
    assert_equal 1, row(summary, "Google ebc").inquiries
    assert_nil summary.paid_total.spend_minor
    assert_nil summary.paid_total.cost_per_inquiry
    assert_nil summary.paid_total.cost_per_qualified
    assert_nil summary.paid_total.cost_per_booking
    assert_nil summary.roas
    assert_not summary.spend_entered?
    assert_equal [ "Meta social" ], summary.missing_spend_labels
  end

  test "a quiet week still lists both paid channels" do
    labels = WeeklyReport::Summary.new(week_start: WEEK).rows.map(&:label)
    assert_equal [ "Google", "Meta" ], labels
    assert_not WeeklyReport::Summary.new(week_start: WEEK).spend_entered?
  end

  test "deposits count as bookings for the lead's channel with travelers toward the goal" do
    lead = inquiry("Booker", source: "meta_ads", campaign: "social", fit_band: "strong", at: Time.zone.local(2026, 9, 1, 9))
    client = travel_to(Time.zone.local(2026, 9, 2, 9)) { lead.convert_to_client! }
    client.update!(perfectbook_contact_id: 42)
    seen = Time.zone.local(2026, 9, 17, 12)
    PerfectBook::Booking.create!(perfectbook_id: 1, perfectbook_contact_id: 42, trip_name: "Everest Base Camp",
      status: "confirmed", party_size: 2, paid_minor: 50_000, total_minor: 700_000, deposit_seen_at: seen, synced_at: seen)
    PerfectBook::Booking.create!(perfectbook_id: 2, perfectbook_contact_id: 42, trip_name: "Everest Base Camp",
      status: "cancelled", party_size: 3, paid_minor: 50_000, total_minor: 700_000, deposit_seen_at: seen, synced_at: seen)
    PerfectBook::Booking.create!(perfectbook_id: 3, perfectbook_contact_id: 99, trip_name: "Annapurna",
      status: "confirmed", party_size: 2, paid_minor: 50_000, deposit_seen_at: Time.zone.local(2026, 7, 10), synced_at: seen)
    AdSpend.record!(week_start: WEEK, source: "meta_ads", campaign_name: "social", amount_dollars: "350")

    summary = WeeklyReport::Summary.new(week_start: WEEK)
    meta = row(summary, "Meta social")
    assert_equal 1, meta.booked
    assert_equal 35_000, meta.cost_per_booking
    assert_equal 20.0, summary.roas
    assert_equal [ "Everest Base Camp", 1 ], summary.trips.first.then { |trip| [ trip.trip, trip.booked ] }
    year = summary.periods.last
    assert_equal [ "2026", 2, 4 ], [ year.label, year.booked, year.travelers ]
    assert_equal 4, summary.year_travelers
    assert_equal 15, summary.weeks_left_in_year
    assert_equal 0.4, summary.goal_pace
  end

  test "AI fit agreement counts only the captain's own calls" do
    worked = inquiry("Worked", fit_band: "strong")
    dropped = inquiry("Dropped", fit_band: "weak")
    missed = inquiry("Missed", fit_band: "weak")
    auto = inquiry("Auto", fit_band: "strong")
    move(worked, "quoted", at: Time.zone.local(2026, 9, 16, 9))
    travel_to(Time.zone.local(2026, 9, 16, 9)) { Leads::Transition.call(dropped, to: "lost", lost_reason: "not_a_fit") }
    move(missed, "chatting", at: Time.zone.local(2026, 9, 16, 9))
    move(auto, "chatting", at: Time.zone.local(2026, 9, 16, 9), actor: :automation)

    assert_equal({ agreed: 2, total: 3 }, WeeklyReport::Summary.new(week_start: WEEK).ai_agreement)
  end

  test "reply speed counts outbound mail and lists leads still waiting" do
    answered = inquiry("Answered", at: Time.zone.local(2026, 9, 15, 10))
    conversation = Conversation.create!(subject: "Everest", linkable: answered, last_message_at: Time.current)
    conversation.messages.create!(direction: "out", status: "sent", subject: "Re: Everest", to_addrs: "a@example.com",
      text_body: "Hello", sent_at: Time.zone.local(2026, 9, 15, 13))
    waiting = inquiry("Waiting", at: Time.zone.local(2026, 9, 18, 10))
    inquiry("Fresh", at: Time.zone.local(2026, 9, 20, 20))

    summary = WeeklyReport::Summary.new(week_start: WEEK)
    assert_equal 3.0, summary.median_first_reply_hours
    assert_equal [ waiting ], summary.waiting
    assert_equal 2, summary.unanswered_in_week
  end
  test "notes and stage changes are not replies and old unanswered inquiries remain visible" do
    lead = inquiry("Details submitted")
    Note.create!(notable: lead, body: "Visitor filled in details")
    move(lead, "chatting", at: Time.zone.local(2026, 9, 16, 9))
    old = inquiry("Old unanswered", at: Time.zone.local(2026, 7, 1))
    summary = WeeklyReport::Summary.new(week_start: WEEK)
    assert_nil summary.median_first_reply_hours
    assert_equal [ old, lead ], summary.waiting
    assert_equal 1, summary.unanswered_in_week
  end

  test "only successful outbound email counts including conversations moved to the converted client" do
    lead = inquiry("Converted")
    client = lead.convert_to_client!
    conversation = Conversation.create!(subject: "Trip", linkable: client, last_message_at: Time.current)
    conversation.messages.create!(direction: "out", status: "failed", subject: "Failed", to_addrs: "a@example.com",
      text_body: "Hello", sent_at: Time.zone.local(2026, 9, 15, 11))
    assert_nil WeeklyReport::Summary.new(week_start: WEEK).median_first_reply_hours
    conversation.messages.create!(direction: "out", status: "sent", subject: "Reply", to_addrs: "a@example.com",
      text_body: "Hello", sent_at: Time.zone.local(2026, 9, 15, 13))
    assert_equal 3.0, WeeklyReport::Summary.new(week_start: WEEK).median_first_reply_hours
  end

  test "qualification requires an owner move to chatting or quoted" do
    inquiry("Initial chatting", fit_band: "strong", status: "chatting")
    converted = inquiry("Converted directly", fit_band: "strong")
    converted.convert_to_client!
    nudged = inquiry("Nudged", fit_band: "strong")
    move(nudged, "nudged", at: Time.zone.local(2026, 9, 16))
    valid = inquiry("Qualified", fit_band: "possible")
    move(valid, "chatting", at: Time.zone.local(2026, 9, 16))
    move(valid, "quoted", at: Time.zone.local(2026, 9, 22))
    assert_equal 1, WeeklyReport::Summary.new(week_start: WEEK).total.qualified
    assert_equal 0, WeeklyReport::Summary.new(week_start: WEEK + 7).total.qualified
  end

  test "the latest owner rejection supersedes an earlier positive judgment" do
    lead = inquiry("Rejected", fit_band: "strong")
    move(lead, "chatting", at: Time.zone.local(2026, 9, 16))
    travel_to(Time.zone.local(2026, 9, 17)) { Leads::Transition.call(lead, to: "lost", lost_reason: "not_a_fit") }
    assert_equal({ agreed: 0, total: 1 }, WeeklyReport::Summary.new(week_start: WEEK).ai_agreement)
  end

  test "booking attribution uses the lead converted before the deposit" do
    original = inquiry("Original", source: "google_ads", campaign: "first")
    client = travel_to(Time.zone.local(2026, 9, 16)) { original.convert_to_client! }
    client.update!(perfectbook_contact_id: 42)
    returning = inquiry("Returning", source: "meta_ads", campaign: "return")
    returning.update!(converted_client: client, converted_at: Time.zone.local(2026, 9, 20))
    seen = Time.zone.local(2026, 9, 17)
    PerfectBook::Booking.create!(perfectbook_id: 1, perfectbook_contact_id: 42, status: "confirmed",
      party_size: 2, paid_minor: 50_000, total_minor: 700_000, deposit_seen_at: seen, synced_at: seen)
    summary = WeeklyReport::Summary.new(week_start: WEEK)
    assert_equal 1, row(summary, "Google first").booked
    assert_equal 0, row(summary, "Meta return").booked
  end

  test "returning leads without a campaign do not inherit the client's campaign" do
    original = inquiry("Original", source: "google_ads", campaign: "EBC", perfectbook_contact_id: 42)
    client = travel_to(Time.zone.local(2026, 9, 15)) { original.convert_to_client! }
    returning = inquiry("Returning", source: "meta_ads", perfectbook_contact_id: 42)
    travel_to(Time.zone.local(2026, 9, 16)) { returning.convert_to_client! }
    assert_equal client, returning.reload.converted_client
    assert_equal "EBC", client.reload.campaign_name
    seen = Time.zone.local(2026, 9, 17)
    PerfectBook::Booking.create!(perfectbook_id: 1, perfectbook_contact_id: 42, status: "confirmed",
      party_size: 2, paid_minor: 50_000, total_minor: 700_000, deposit_seen_at: seen, synced_at: seen)

    summary = WeeklyReport::Summary.new(week_start: WEEK)
    assert_equal 1, row(summary, "Meta").booked
    assert_equal 700_000, row(summary, "Meta").booked_value_minor
    assert_nil row(summary, "Meta EBC")
    assert_equal 0, row(summary, "Google EBC").booked
  end

  test "owner rejection survives automated reason changes and reopening" do
    lead = inquiry("Rejected", fit_band: "strong")
    travel_to(Time.zone.local(2026, 9, 16)) { Leads::Transition.call(lead, to: "lost", lost_reason: "not_a_fit") }
    event = lead.activity_events.find_by!(kind: "stage_change")
    assert_equal "not_a_fit", event.metadata["lost_reason"]
    travel_to(Time.zone.local(2026, 9, 17)) do
      Leads::Transition.call(lead, to: "lost", lost_reason: "dates", actor: :automation)
    end
    assert_equal({ agreed: 0, total: 1 }, WeeklyReport::Summary.new(week_start: WEEK).ai_agreement)
    move(lead, "chatting", at: Time.zone.local(2026, 9, 18), actor: :automation)
    assert_nil lead.reload.lost_reason
    assert_equal({ agreed: 0, total: 1 }, WeeklyReport::Summary.new(week_start: WEEK).ai_agreement)
  end

  test "legacy owner judgments use the current reason when no snapshot exists" do
    lead = inquiry("Legacy rejection", fit_band: "strong", status: "lost", lost_reason: "not_a_fit")
    lead.activity_events.create!(kind: "stage_change", summary: "Moved to Lost",
      occurred_at: Time.zone.local(2026, 9, 16), metadata: { "to" => "lost", "actor" => "captain" })
    assert_equal({ agreed: 0, total: 1 }, WeeklyReport::Summary.new(week_start: WEEK).ai_agreement)
  end

  test "AI agreement windows owner judgments instead of inquiry dates" do
    older = inquiry("Old inquiry recent call", at: Time.zone.local(2026, 7, 1), fit_band: "strong")
    expired = inquiry("Old call", at: Time.zone.local(2026, 7, 1), fit_band: "weak")
    future = inquiry("Future call", fit_band: "weak")
    move(older, "chatting", at: Time.zone.local(2026, 9, 16))
    move(expired, "chatting", at: Time.zone.local(2026, 8, 1))
    move(future, "chatting", at: Time.zone.local(2026, 9, 22))
    assert_equal({ agreed: 1, total: 1 }, WeeklyReport::Summary.new(week_start: WEEK).ai_agreement)
    travel_to(Time.zone.local(2026, 9, 22)) { Leads::Transition.call(older, to: "lost", lost_reason: "not_a_fit") }
    assert_equal({ agreed: 1, total: 1 }, WeeklyReport::Summary.new(week_start: WEEK).ai_agreement)
  end

  test "conversion judgments also use the report's four week window" do
    recent = inquiry("Recent conversion", at: Time.zone.local(2026, 7, 1), fit_band: "strong")
    expired = inquiry("Old conversion", at: Time.zone.local(2026, 7, 1), fit_band: "weak")
    future = inquiry("Future conversion", fit_band: "weak")
    travel_to(Time.zone.local(2026, 9, 16)) { recent.convert_to_client! }
    travel_to(Time.zone.local(2026, 8, 1)) { expired.convert_to_client! }
    travel_to(Time.zone.local(2026, 9, 22)) { future.convert_to_client! }
    assert_equal({ agreed: 1, total: 1 }, WeeklyReport::Summary.new(week_start: WEEK).ai_agreement)
  end

  test "every trip is listed and unknown timing is incomplete" do
    6.times do |i|
      inquiry("Trip #{i}", trip_title: "Trip #{i}", party_size: 2, timing_unknown: true)
    end
    inquiry("Complete", trip_title: "Seventh", party_size: 2, travel_month: 1)
    summary = WeeklyReport::Summary.new(week_start: WEEK)
    assert_equal 7, summary.trips.size
    assert_equal 1, summary.details_filled
  end

  test "goals milestones review dates and flags follow the approved schedule" do
    assert_equal 10, WeeklyReport::Summary.new(week_start: WEEK).travelers_goal
    assert_equal 100, WeeklyReport::Summary.new(week_start: Date.new(2027, 1, 4)).travelers_goal
    assert_nil WeeklyReport::Summary.new(week_start: Date.new(2028, 1, 3)).travelers_goal
    [ [ Date.new(2026, 10, 10), Date.new(2026, 10, 10) ],
      [ Date.new(2026, 10, 11), Date.new(2026, 10, 24) ],
      [ Date.new(2026, 10, 25), Date.new(2026, 11, 7) ],
      [ Date.new(2026, 11, 8), Date.new(2027, 1, 31) ],
      [ Date.new(2027, 2, 1), Date.new(2027, 2, 28) ],
      [ Date.new(2027, 2, 28), Date.new(2027, 2, 28) ] ].each do |today, expected|
      assert_equal expected, WeeklyReport::Summary.new(today: today).next_review
    end
    seen = Time.zone.local(2026, 10, 2)
    PerfectBook::Booking.create!(perfectbook_id: 1, perfectbook_contact_id: 99, status: "confirmed", party_size: 2,
      paid_minor: 50_000, deposit_seen_at: seen, synced_at: seen)
    summary = WeeklyReport::Summary.new(week_start: Date.new(2026, 9, 28), today: Date.new(2026, 10, 5))
    assert_equal({ deadline: Date.new(2026, 10, 31), target: 2, travelers: 2 }, summary.milestone)
    assert_includes summary.flags, "No spend entered for the week"
    lead = inquiry("Expensive", campaign: "EBC", fit_band: "strong")
    move(lead, "chatting", at: Time.zone.local(2026, 9, 16))
    AdSpend.record!(week_start: WEEK, source: "google_ads", campaign_name: "EBC", amount_dollars: "301")
    flags = WeeklyReport::Summary.new(week_start: WEEK).flags
    assert_includes flags, "Google EBC cost per qualified inquiry over $300"
    assert_includes flags, "1 inquiry waiting over 24 h"
  end
end
