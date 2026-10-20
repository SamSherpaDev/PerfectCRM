# Everything the Today view and the morning digest need, in one place.
#
# Waiting-on-you threads mirror the Inbox "Waiting on you" tab (linked
# owners only; unknown senders wait in triage). Quotes-out counts live
# sent and viewed quotes whose valid-until has not passed.
# New leads and active clients reuse the models' own vocabulary: the
# Leads "New" tab (Lead.in_new_tab), and every client that is not archived.
# Departure windows read the mirrored PerfectBook bookings.
module Today
  class Summary
    DEPARTING_WITHIN = 14.days
    RETURNED_WITHIN = 7.days
    MAX_CALL_ATTEMPTS = 3

    CallEntry = Data.define(:lead, :attempt, :attempt_label, :last_call, :waited_since)

    ATTEMPT_LABELS = {
      1 => "1st try",
      2 => "2nd try",
      3 => "3rd try"
    }.freeze

    attr_reader :today, :now, :calendar_view, :calendar_date

    def initialize(now: Time.current, today: now.to_date, calendar_date: nil, calendar_view: nil)
      @today = today
      @now = now
      @calendar_view = %w[week month].include?(calendar_view.to_s) ? calendar_view.to_s : "week"
      @calendar_date = parse_calendar_date(calendar_date) || @today
    end
    # Threads still needing a personal response (automatic greetings do not clear them).
    def waiting_on_you
      waiting_threads.count
    end

    def replies_waiting
      waiting_threads.limit(5).to_a
    end

    def unlinked_inquiries
      @unlinked_inquiries ||= Leads::UnlinkedInquiries.new(now: @now).messages
    end

    # Sent or viewed quotes whose valid-until has not passed.
    def quotes_out
      Quote.live.where.not(id: Quote.expired.select(:id))
        .where.not(id: Quote.where(lead_id: Lead.archived.or(Lead.not_interested).select(:id)).select(:id)).count
    end

    # Matches the Leads "New" tab: untriaged active leads in New, Chatting, or Nudged.
    def new_leads
      Lead.in_new_tab.count
    end

    # Daily call list in priority order:
    # (a) new inquiries with a phone and no call yet, oldest first;
    # (b) leads with a phone whose last call was voicemail or no_answer and
    #     that are due another try (attempt 2 due 1 day after attempt 1;
    #     attempt 3 due 2 days after attempt 2; at most 3 attempts).
    # Leads drop off once a call connects, they are marked Not interested,
    # spam or archived, have a scheduled call, or have used 3 attempts.
    def call_entries
      @call_entries ||= begin
        candidates = Lead.open
          .where(not_interested_marked_at: nil)
          .where.not(id: Lead.spam.select(:id))
          .where.not(id: ScheduledCall.scheduled.select(:lead_id))
          .includes(:activity_events, :tags)

        uncalled = []
        retries = []

        candidates.each do |lead|
          next if lead.display_phone.blank?

          waited_since = lead.received_at || lead.created_at
          calls = lead.activity_events
            .select { |event| event.kind == "call" && event.occurred_at >= waited_since }
            .sort_by { |event| [ event.occurred_at, event.id ] }

          if calls.empty?
            next unless lead.status == "new"

            uncalled << CallEntry.new(
              lead: lead,
              attempt: 1,
              attempt_label: ATTEMPT_LABELS.fetch(1),
              last_call: nil,
              waited_since: waited_since
            )
            next
          end

          next if calls.size >= MAX_CALL_ATTEMPTS
          next if calls.any? { |call| call_connected?(call) }

          last_call = calls.last
          next unless call_outcome(last_call).in?(%w[voicemail no_answer])

          attempt = calls.size + 1
          days_wait = attempt == 2 ? 1 : 2
          due = last_call.occurred_at <= @now - days_wait.days ||
            last_call.occurred_at.in_time_zone.to_date <= @today - days_wait.days
          next unless due

          retries << CallEntry.new(
            lead: lead,
            attempt: attempt,
            attempt_label: ATTEMPT_LABELS.fetch(attempt),
            last_call: last_call,
            waited_since: waited_since
          )
        end

        uncalled.sort_by! { |entry| [ entry.waited_since, entry.lead.id ] }
        retries.sort_by! { |entry| [ entry.attempt, entry.last_call.occurred_at, entry.waited_since, entry.lead.id ] }
        uncalled + retries
      end
    end

    def not_yet_called
      @not_yet_called ||= call_entries.map(&:lead)
    end

    # Clients on the books: everything that is not archived.
    def active_clients
      Client.active.count
    end

    def overdue
      Task.overdue.ordered.includes(:subject, :template)
    end

    def followups_due
      Task.due_today.ordered.includes(:subject, :template)
    end

    def followups
      Task.due_within_week.ordered.includes(:subject, :template)
    end

    def departing_soon
      PerfectBook::Booking.available
        .where(start_date: @today..@today + DEPARTING_WITHIN)
        .order(:start_date, :id)
    end

    # Back from the mountains: the departure ended within the last 7 days.
    def returned
      PerfectBook::Booking.available
        .where(end_date: (@today - RETURNED_WITHIN)..@today)
        .order(:end_date, :id)
    end

    def subject_for(booking)
      Tasks::Automatic.subject_for(booking)
    end

    def missed_calls
      @missed_calls ||= ScheduledCall.visible.missed(@now).includes(lead: :tags).to_a
    end

    def todays_calls
      @todays_calls ||= ScheduledCall.visible.scheduled.for_day(@today)
        .where("scheduled_calls.scheduled_at >= ?", @now).includes(lead: :tags).to_a
    end

    def upcoming_calls
      @upcoming_calls ||= ScheduledCall.visible.upcoming(@now).includes(lead: :tags).to_a
    end

    def later_upcoming_calls
      @later_upcoming_calls ||= ScheduledCall.visible.scheduled
        .where("scheduled_calls.scheduled_at > ?", @today.in_time_zone.end_of_day)
        .order(scheduled_at: :asc, id: :asc).includes(lead: :tags).to_a
    end

    def week_start
      @calendar_date.beginning_of_week(:monday)
    end

    def week_end
      @calendar_date.end_of_week(:monday)
    end

    def week_days
      (week_start..week_end).to_a
    end

    def month_start
      @calendar_date.beginning_of_month
    end

    def month_end
      @calendar_date.end_of_month
    end

    def month_grid_start
      month_start.beginning_of_week(:monday)
    end

    def month_grid_end
      month_end.end_of_week(:monday)
    end

    def month_days
      (month_grid_start..month_grid_end).to_a
    end

    def prev_calendar_date
      @calendar_view == "month" ? (month_start - 1.month) : (week_start - 7.days)
    end

    def next_calendar_date
      @calendar_view == "month" ? (month_start + 1.month) : (week_start + 7.days)
    end

    def calendar_calls_by_day
      @calendar_calls_by_day ||= begin
        range_start = @calendar_view == "month" ? month_grid_start : week_start
        range_end = @calendar_view == "month" ? month_grid_end : week_end
        calls = ScheduledCall.visible.scheduled
          .between(range_start.in_time_zone.beginning_of_day, range_end.in_time_zone.end_of_day)
          .includes(:lead).to_a
        calls.group_by { |call| call.scheduled_at.in_time_zone.to_date }
      end
    end

    private

    def parse_calendar_date(raw)
      return nil if raw.blank?
      return raw.to_date if raw.respond_to?(:to_date) && !raw.is_a?(String)

      Date.iso8601(raw.to_s)
    rescue ArgumentError
      nil
    end

    def one_business_day_ago
      as_of = @now
      # Freeze elapsed business time at Saturday midnight throughout the weekend.
      as_of = as_of.beginning_of_week(:monday) + 5.days if as_of.saturday? || as_of.sunday?
      cutoff = as_of - 1.day
      cutoff -= 1.day while cutoff.saturday? || cutoff.sunday?
      cutoff
    end

    def waiting_threads
      Conversation.where(ignored: false).ordered.preload(:linkable, :messages)
        .merge(Conversation.waiting_on_you).linked
    end

    def call_outcome(event)
      event.metadata.is_a?(Hash) ? event.metadata["outcome"].to_s : ""
    end

    def call_connected?(event)
      outcome = call_outcome(event)
      outcome == "connected" || outcome.blank?
    end
  end
end
