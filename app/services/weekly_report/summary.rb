# The numbers behind the Monday ads report (README.md, "Weekly ads
# report"). Weeks run Monday to Sunday, Pacific time. Each weekly count is
# an event inside that week: an inquiry received, a lead qualified or
# quoted, a deposit first seen. Attribution is the lead's own source and
# campaign, the CRM's system of record.
module WeeklyReport
  class Summary
    PAID_SOURCES = AdSpend::SOURCES
    SOURCE_LABELS = {
      "google_ads" => "Google", "meta_ads" => "Meta", "website_form" => "Website form",
      "email" => "Email", "referral" => "Referral", "manual" => "Manual"
    }.freeze
    UNLINKED_LABEL = "Booked outside the CRM"
    QUALIFIED_FITS = %w[strong possible].freeze
    QUALIFIED_STAGES = %w[chatting quoted nudged].freeze
    WAITING_AFTER = 24.hours
    WAITING_LOOKBACK = 30.days
    AGREEMENT_WINDOW = 28.days
    TOP_TRIPS = 5

    Row = Struct.new(:source, :campaign, :spend_minor, :inquiries, :qualified, :quoted, :booked,
      :booked_value_minor, keyword_init: true) do
      def label
        base = source ? SOURCE_LABELS.fetch(source, source.humanize) : UNLINKED_LABEL
        campaign.present? ? "#{base} #{campaign}" : base
      end

      def cost_per_inquiry = Summary.ratio(spend_minor, inquiries)
      def cost_per_qualified = Summary.ratio(spend_minor, qualified)
      def cost_per_booking = Summary.ratio(spend_minor, booked)
    end

    Period = Struct.new(:label, :inquiries, :qualified, :booked, :travelers, :spend_minor, keyword_init: true)
    TripRow = Struct.new(:trip, :inquiries, :qualified, :booked, keyword_init: true)

    attr_reader :week_start, :week_end, :today

    def self.last_complete_week(today: Date.current)
      today.beginning_of_week(:monday) - 7
    end

    # "Sep 14-20", or "Sep 28-Oct 4" across a month end.
    def self.week_label(week_start)
      week_start = week_start.to_date.beginning_of_week(:monday)
      week_end = week_start + 6
      if week_end.month == week_start.month
        "#{week_start.strftime('%b %-d')}-#{week_end.strftime('%-d')}"
      else
        "#{week_start.strftime('%b %-d')}-#{week_end.strftime('%b %-d')}"
      end
    end

    def self.ratio(minor, count)
      return nil if minor.nil? || count.to_i.zero?

      (minor.to_f / count).round
    end

    def initialize(week_start: self.class.last_complete_week, today: Date.current)
      @week_start = week_start.to_date.beginning_of_week(:monday)
      @week_end = @week_start + 6
      @today = today
    end

    def range
      @week_start.in_time_zone.beginning_of_day..@week_end.in_time_zone.end_of_day
    end

    def rows
      @rows ||= build_rows(range, spends: AdSpend.for_week(week_start))
    end

    # Every source: the week's volume.
    def total
      @total ||= sum_rows(rows)
    end

    # Google and Meta only: what the spend bought.
    def paid_total
      @paid_total ||= sum_rows(rows.select { |row| PAID_SOURCES.include?(row.source) })
    end

    def spend_entered?
      AdSpend.for_week(week_start).exists?
    end

    # Paid bookings' value over spend.
    def roas
      return nil if paid_total.spend_minor.to_i.zero? || paid_total.booked_value_minor.to_i.zero?

      (paid_total.booked_value_minor.to_f / paid_total.spend_minor).round(1)
    end

    # Month and year to date through the report week's Sunday.
    def periods
      @periods ||= begin
        month_start = week_end.beginning_of_month
        year_start = week_end.beginning_of_year
        [
          period(month_start.strftime("%B"), month_start),
          period(year_start.year.to_s, year_start)
        ]
      end
    end

    def travelers_goal
      Setting.current.travelers_goal
    end

    def year_travelers
      periods.last.travelers
    end

    def weeks_left_in_year
      ((week_end.end_of_year - week_end).to_i / 7.0).ceil
    end

    # Travelers still needed each remaining week to reach the goal.
    def goal_pace
      goal = travelers_goal
      return nil if goal.nil?

      remaining = [ goal - year_travelers, 0 ].max
      return 0.0 if remaining.zero?

      remaining.fdiv([ weeks_left_in_year, 1 ].max).round(1)
    end

    def median_first_reply_hours
      hours = week_inquiries.filter_map do |lead|
        replied = first_reply_at(lead)
        next if replied.nil?

        [ (replied - inquired_at(lead)) / 1.hour, 0 ].max
      end.sort
      return nil if hours.empty?

      mid = hours.length / 2
      median = hours.length.odd? ? hours[mid] : (hours[mid - 1] + hours[mid]) / 2.0
      median.round(1)
    end

    def unanswered_in_week
      week_inquiries.count { |lead| first_reply_at(lead).nil? }
    end

    # Open leads with no reply yet, received more than a day ago.
    def waiting
      @waiting ||= counted_leads
        .where(converted_client_id: nil).where.not(status: "lost")
        .where("COALESCE(received_at, leads.created_at) >= ?", (range.last - WAITING_LOOKBACK))
        .where("COALESCE(received_at, leads.created_at) <= ?", Time.current - WAITING_AFTER)
        .to_a.select { |lead| first_reply_at(lead).nil? }
        .sort_by { |lead| inquired_at(lead) }
    end

    def trips
      @trips ||= begin
        by_trip = Hash.new { |hash, key| hash[key] = TripRow.new(trip: key, inquiries: 0, qualified: 0, booked: 0) }
        week_inquiries.each { |lead| by_trip[trip_label(lead)].inquiries += 1 }
        qualified_in(range).each { |lead| by_trip[trip_label(lead)].qualified += 1 }
        deposits_in(range).each { |booking| by_trip[booking.trip_name.presence || "No trip named"].booked += 1 }
        by_trip.values.sort_by { |row| [ -row.booked, -row.qualified, -row.inquiries, row.trip ] }.first(TOP_TRIPS)
      end
    end

    def placements
      week_inquiries.group_by { |lead| lead.placement.presence || "not recorded" }
        .transform_values(&:size).sort_by { |name, count| [ -count, name ] }
    end

    # Inquiries that said which trip, which month, and how many travel.
    def details_filled
      week_inquiries.count do |lead|
        trip_label(lead) != "No trip named" && (lead.travel_month.present? || lead.timing_unknown?) &&
          lead.party_size.present?
      end
    end

    def suspected_spam_count
      Lead.active.where(id: spam_lead_ids)
        .where("COALESCE(received_at, leads.created_at) BETWEEN ? AND ?", range.first, range.last).count
    end

    # AI fit against the captain's own call over the last four weeks:
    # strong or possible should be worked; weak should be lost as not a fit.
    # Only the captain's moves count, never an automation's.
    def ai_agreement
      window = (range.last - AGREEMENT_WINDOW)..range.last
      judged = counted_leads.where.not(fit_band: [ nil, "" ])
        .where("COALESCE(received_at, leads.created_at) BETWEEN ? AND ?", window.first, window.last).to_a
      worked = captain_moves_to(judged.map(&:id), QUALIFIED_STAGES)
      dropped = captain_moves_to(judged.map(&:id), %w[lost])
      verdicts = judged.map do |lead|
        owner_yes = lead.converted? || worked.key?(lead.id)
        owner_no = !owner_yes && dropped.key?(lead.id) && lead.status == "lost" && lead.lost_reason == "not_a_fit"
        next unless owner_yes || owner_no

        QUALIFIED_FITS.include?(lead.fit_band) == owner_yes
      end.compact
      { agreed: verdicts.count(true), total: verdicts.size }
    end

    def headline
      "#{pluralize(total.inquiries, 'inquiry', 'inquiries')}, #{total.qualified} qualified, #{total.booked} booked"
    end

    def week_label
      self.class.week_label(week_start)
    end

    private

    # Paid leads split by campaign, matched to spend by name in any case.
    # A channel whose spend was entered only as a channel total keeps its
    # leads on that one row, so cost per inquiry stays honest.
    def build_rows(window, spends:)
      rows = {}
      totals_only = spends.group_by(&:source).select { |_, list| list.all? { |spend| spend.campaign_name.blank? } }.keys
      row_for = lambda do |source, campaign|
        split = PAID_SOURCES.include?(source) && !totals_only.include?(source)
        name = split ? campaign.to_s.strip.presence : nil
        rows[[ source, name&.downcase ]] ||= Row.new(source: source, campaign: name, spend_minor: nil,
          inquiries: 0, qualified: 0, quoted: 0, booked: 0, booked_value_minor: 0)
      end
      PAID_SOURCES.each { |source| row_for.call(source, nil) }
      spends.each do |spend|
        row = row_for.call(spend.source, spend.campaign_name)
        row.spend_minor = row.spend_minor.to_i + spend.amount_minor
      end
      inquiries_in(window).each { |lead| row_for.call(lead.source, lead.campaign_name).inquiries += 1 }
      qualified_in(window).each { |lead| row_for.call(lead.source, lead.campaign_name).qualified += 1 }
      quoted_in(window).each { |lead| row_for.call(lead.source, lead.campaign_name).quoted += 1 }
      deposits_in(window).each do |booking|
        lead, client = booking_origin(booking)
        source = lead&.source || client&.source.presence
        row = row_for.call(source, lead&.campaign_name || client&.campaign_name)
        row.booked += 1
        row.booked_value_minor += booking.total_minor.to_i if booking.currency.to_s.upcase == "USD"
      end
      kept = rows.values.reject { |row| idle?(row) }
      # A paid channel keeps one row even in a quiet week, so the report
      # always shows where money could have gone.
      PAID_SOURCES.each do |source|
        kept << rows[[ source, nil ]] if kept.none? { |row| row.source == source }
      end
      kept.sort_by { |row| row_order(row) }
    end

    def idle?(row)
      row.spend_minor.nil? && (row.inquiries + row.qualified + row.quoted + row.booked).zero?
    end

    # Paid channels first, then the known sources, then client-only
    # sources, then bookings with no CRM origin.
    def row_order(row)
      group = row.source ? SOURCE_LABELS.keys.index(row.source) || SOURCE_LABELS.size : SOURCE_LABELS.size + 1
      [ group, row.label ]
    end

    def sum_rows(list)
      spend = list.map(&:spend_minor).compact
      Row.new(source: nil, campaign: nil, spend_minor: spend.empty? ? nil : spend.sum,
        inquiries: list.sum(&:inquiries), qualified: list.sum(&:qualified), quoted: list.sum(&:quoted),
        booked: list.sum(&:booked), booked_value_minor: list.sum(&:booked_value_minor))
    end

    def period(label, from)
      window = from.in_time_zone.beginning_of_day..range.last
      spend = AdSpend.where(week_start: from..week_start).sum(:amount_minor)
      deposits = deposits_in(window)
      Period.new(label: label, inquiries: inquiries_in(window).size, qualified: qualified_in(window).size,
        booked: deposits.size, travelers: deposits.sum { |booking| booking.party_size.to_i }, spend_minor: spend)
    end

    # Leads that count as inquiries: not archived (tests and junk are
    # archived) and not flagged as suspected spam at intake.
    def counted_leads
      Lead.active.where.not(id: spam_lead_ids)
    end

    def spam_lead_ids
      @spam_lead_ids ||= Tagging.joins(:tag)
        .where(taggable_type: "Lead", tags: { name: Lead::SUSPECTED_SPAM_TAG }).pluck(:taggable_id)
    end

    def week_inquiries
      @week_inquiries ||= inquiries_in(range)
    end

    def inquiries_in(window)
      @inquiries ||= {}
      @inquiries[window] ||= counted_leads
        .where("COALESCE(received_at, leads.created_at) BETWEEN ? AND ?", window.first, window.last).to_a
    end

    # The R1 rule: AI fit strong or possible, and the captain moved the lead
    # to Chatting or Quoted (or on to Nudged or Won). Dated by that move.
    def qualified_in(window)
      @qualified ||= {}
      @qualified[window] ||= qualification_times.select { |_, at| window.cover?(at) }.keys
    end

    def qualification_times
      @qualification_times ||= begin
        leads = counted_leads.where(fit_band: QUALIFIED_FITS).to_a
        moves = captain_moves_to(leads.map(&:id), QUALIFIED_STAGES)
        # A lead the captain entered already in a later stage never moved.
        moved = ActivityEvent.where(subject_type: "Lead", kind: "stage_change", subject_id: leads.map(&:id))
          .distinct.pluck(:subject_id).to_set
        leads.each_with_object({}) do |lead, times|
          at = [ moves[lead.id], lead.converted_at ].compact.min
          at ||= inquired_at(lead) if QUALIFIED_STAGES.include?(lead.status) && !moved.include?(lead.id)
          times[lead] = at if at
        end
      end
    end

    # First move to Quoted or first quote sent, whichever came first.
    def quoted_in(window)
      @quoted ||= {}
      @quoted[window] ||= quote_times.select { |_, at| window.cover?(at) }.keys
    end

    def quote_times
      @quote_times ||= begin
        moves = captain_moves_to(nil, %w[quoted])
        sent = Quote.where.not(lead_id: nil).where.not(sent_at: nil).group(:lead_id).minimum(:sent_at)
        ids = moves.keys | sent.keys
        counted_leads.where(id: ids).to_a.each_with_object({}) do |lead, times|
          times[lead] = [ moves[lead.id], sent[lead.id] ].compact.min
        end
      end
    end

    # { lead_id => first time the captain moved it into one of stages }.
    def captain_moves_to(lead_ids, stages)
      scope = ActivityEvent.where(subject_type: "Lead", kind: "stage_change")
      scope = scope.where(subject_id: lead_ids) if lead_ids
      scope.pluck(:subject_id, :occurred_at, :metadata).each_with_object({}) do |(id, at, metadata), firsts|
        data = metadata.is_a?(Hash) ? metadata : JSON.parse(metadata.to_s) rescue {}
        next unless stages.include?(data["to"]) && data["actor"].to_s != "automation"

        firsts[id] = at if firsts[id].nil? || at < firsts[id]
      end
    end

    # Bookings whose deposit arrived in the window, minus any since
    # cancelled, voided, or refunded.
    def deposits_in(window)
      @deposits ||= {}
      @deposits[window] ||= PerfectBook::Booking.where("paid_minor > 0")
        .where(deposit_seen_at: window)
        .where("status IS NULL OR status NOT IN (?)", TemplateContext::INACTIVE_BOOKING_STATUSES).to_a
    end

    # The lead a booking came from: the client's latest converted lead, or
    # an unconverted lead holding the same PerfectBook contact.
    def booking_origin(booking)
      client = Client.find_by(perfectbook_contact_id: booking.perfectbook_contact_id)
      lead = client&.converted_leads&.order(:converted_at, :id)&.last
      lead ||= Lead.where(perfectbook_contact_id: booking.perfectbook_contact_id).order(:created_at, :id).last
      [ lead, client ]
    end

    def inquired_at(lead)
      lead.received_at || lead.created_at
    end

    def trip_label(lead)
      lead.trip_title.presence || lead.trip_interest.presence || lead.trip_handle.to_s.tr("-", " ").capitalize.presence ||
        "No trip named"
    end

    # First sign the captain answered: an outbound email, a logged note, or
    # the captain moving the lead on. Mail keeps its thread after conversion.
    def first_reply_at(lead)
      @first_replies ||= {}
      return @first_replies[lead.id] if @first_replies.key?(lead.id)

      since = inquired_at(lead)
      owners = [ [ "Lead", lead.id ] ]
      owners << [ "Client", lead.converted_client_id ] if lead.converted_client_id
      conversation_ids = owners.flat_map do |type, id|
        Conversation.where(linkable_type: type, linkable_id: id).pluck(:id)
      end
      candidates = []
      candidates << Message.outbound.where(conversation_id: conversation_ids, status: %w[sent received])
        .where("sent_at >= ?", since).minimum(:sent_at)
      candidates << Note.where(notable_type: "Lead", notable_id: lead.id).where("created_at >= ?", since).minimum(:created_at)
      candidates << captain_moves_to([ lead.id ], Lead::STATUSES + [ "won" ])[lead.id]
      candidates << lead.converted_at
      @first_replies[lead.id] = candidates.compact.select { |at| at >= since }.min
    end

    def pluralize(count, singular, plural)
      "#{count} #{count == 1 ? singular : plural}"
    end
  end
end
