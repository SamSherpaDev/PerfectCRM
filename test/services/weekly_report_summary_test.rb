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
    inquiry("Weak", campaign: "EBC_search", fit_band: "weak")
    auto = inquiry("Auto chat", campaign: "ebc_search", fit_band: "possible")
    inquiry("Meta ask", source: "meta_ads")
    inquiry("Form", source: "website_form")
    inquiry("Before the week", at: Time.zone.local(2026, 9, 13, 23))
    inquiry("Archived test").archive!
    inquiry("Spam", tag_list: Lead::SUSPECTED_SPAM_TAG)
    move(strong, "chatting", at: Time.zone.local(2026, 9, 16, 9))
    move(auto, "chatting", at: Time.zone.local(2026, 9, 16, 9), actor: :automation)
    AdSpend.record!(week_start: WEEK, source: "google_ads", campaign_name: "EBC_Search", amount_dollars: "126")
    AdSpend.record!(week_start: WEEK, source: "meta_ads", campaign_name: "", amount_dollars: "140")

    summary = WeeklyReport::Summary.new(week_start: WEEK)
    google = row(summary, "Google EBC_Search")
    assert_equal [ 12_600, 3, 1 ], [ google.spend_minor, google.inquiries, google.qualified ]
    assert_equal 4_200, google.cost_per_inquiry
    assert_equal 12_600, google.cost_per_qualified
    meta = row(summary, "Meta")
    assert_equal [ 14_000, 1, 0 ], [ meta.spend_minor, meta.inquiries, meta.qualified ]
    assert_nil meta.cost_per_qualified
    assert_equal 1, row(summary, "Website form").inquiries
    assert_equal [ 5, 1, 26_600 ], [ summary.total.inquiries, summary.total.qualified, summary.total.spend_minor ]
    assert_equal [ 4, 6_650 ], [ summary.paid_total.inquiries, summary.paid_total.cost_per_inquiry ]
    assert_equal "5 inquiries, 1 qualified, 0 booked", summary.headline
    assert summary.spend_entered?
    assert_equal 1, summary.suspected_spam_count
  end

  test "a channel entered only as a total keeps its campaigns on one row" do
    inquiry("One", campaign: "ebc_search")
    inquiry("Two", campaign: "nepal_tours")
    AdSpend.record!(week_start: WEEK, source: "google_ads", campaign_name: "", amount_dollars: "184")

    rows = WeeklyReport::Summary.new(week_start: WEEK).rows
    google = rows.select { |candidate| candidate.source == "google_ads" }
    assert_equal 1, google.size
    assert_equal [ 18_400, 2, 9_200 ], [ google.first.spend_minor, google.first.inquiries, google.first.cost_per_inquiry ]
  end

  test "a quiet week still lists both paid channels" do
    labels = WeeklyReport::Summary.new(week_start: WEEK).rows.map(&:label)
    assert_equal [ "Google", "Meta" ], labels
    assert_not WeeklyReport::Summary.new(week_start: WEEK).spend_entered?
  end

  test "deposits count as bookings for the lead's channel with travelers toward the goal" do
    Setting.current.update!(travelers_goal: 10)
    lead = inquiry("Booker", source: "meta_ads", fit_band: "strong", at: Time.zone.local(2026, 9, 1, 9))
    client = travel_to(Time.zone.local(2026, 9, 2, 9)) { lead.convert_to_client! }
    client.update!(perfectbook_contact_id: 42)
    seen = Time.zone.local(2026, 9, 17, 12)
    PerfectBook::Booking.create!(perfectbook_id: 1, perfectbook_contact_id: 42, trip_name: "Everest Base Camp",
      status: "confirmed", party_size: 2, paid_minor: 50_000, total_minor: 700_000, deposit_seen_at: seen, synced_at: seen)
    PerfectBook::Booking.create!(perfectbook_id: 2, perfectbook_contact_id: 42, trip_name: "Everest Base Camp",
      status: "cancelled", party_size: 3, paid_minor: 50_000, total_minor: 700_000, deposit_seen_at: seen, synced_at: seen)
    PerfectBook::Booking.create!(perfectbook_id: 3, perfectbook_contact_id: 99, trip_name: "Annapurna",
      status: "confirmed", party_size: 2, paid_minor: 50_000, deposit_seen_at: Time.zone.local(2026, 7, 10), synced_at: seen)
    AdSpend.record!(week_start: WEEK, source: "meta_ads", campaign_name: "", amount_dollars: "350")

    summary = WeeklyReport::Summary.new(week_start: WEEK)
    meta = row(summary, "Meta")
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
end
