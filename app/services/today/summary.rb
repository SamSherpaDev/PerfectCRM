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
    FRESH_INQUIRY_WITHIN = 24.hours
    CALL_LIST_WINDOW = 14.days
    CALL_CADENCE_STARTS_ON = Date.new(2026, 10, 20)
    MAILBOX_STALE_AFTER = 20.minutes
    PERFECTBOOK_STALE_AFTER = 45.minutes

    CallEntry = Data.define(:lead, :attempt, :attempt_label, :last_call, :waited_since, :suggested_window) do
      def initialize(lead:, attempt:, attempt_label:, last_call:, waited_since:, suggested_window: nil)
        super
      end
    end

    ATTEMPT_LABELS = {
      1 => "1st try",
      2 => "2nd try",
      3 => "3rd try"
    }.freeze
    RECONTACT_LABEL = "Re-contact due"

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

    def attention?
      mailbox_attention_label.present? ||
        perfectbook_sync_behind? ||
        failed_replies.any? ||
        set_aside_messages_count.positive?
    end

    def mailbox_attention_label
      return @mailbox_attention_label if defined?(@mailbox_attention_label)

      @mailbox_attention_label = begin
        settings = Setting.current
        last_sync = settings.mailbox_last_sync_at || (settings.mailbox_watched_since if settings.mailbox_connected?)
        error_set = settings.mailbox_last_error.present? ||
          MailSyncState.where(last_error_at: (@now - MailSyncState::ATTENTION_WINDOW)..).where.not(last_error: [ nil, "" ]).exists?
        stale = last_sync.present? && last_sync < @now - MAILBOX_STALE_AFTER
        if error_set || stale
          if last_sync.present?
            "Mailbox has not been read since #{last_sync.in_time_zone.strftime('%-I:%M %P')}"
          else
            "Mailbox has not been read"
          end
        end
      end
    end

    def perfectbook_sync_behind?
      return @perfectbook_sync_behind if defined?(@perfectbook_sync_behind)

      @perfectbook_sync_behind = begin
        last_success = PerfectBook::SyncState.last_success_at
        if last_success.present?
          last_success < @now - PERFECTBOOK_STALE_AFTER
        else
          PerfectBook::SyncState.last_error_row.present?
        end
      end
    end

    def perfectbook_attention_label
      "PerfectBook sync is behind" if perfectbook_sync_behind?
    end

    def failed_replies
      @failed_replies ||= begin
        archived_leads = Lead.archived.select(:id)
        archived_clients = Client.archived.select(:id)
        archived_conversations = Conversation.where(linkable_type: "Lead", linkable_id: archived_leads)
          .or(Conversation.where(linkable_type: "Client", linkable_id: archived_clients))
          .select(:id)

        Message.outbound.where(status: "failed")
          .where.not(id: Message.automatic_replies.select(:id))
          .where.not(id: GuideRequest.where.not(message_id: nil).select(:message_id))
          .where("messages.conversation_id IS NULL OR messages.conversation_id NOT IN (#{archived_conversations.to_sql})")
          .newest_first
          .includes(:group_send, conversation: :linkable)
          .to_a
      end
    end

    def failed_replies_count
      failed_replies.size
    end

    def failed_replies_label
      count = failed_replies_count
      return nil if count.zero?

      count == 1 ? "1 reply was not delivered" : "#{count} replies were not delivered"
    end

    def set_aside_messages_count
      @set_aside_messages_count ||= MailMessageQuarantine.quarantined.count
    end

    def set_aside_messages_label
      count = set_aside_messages_count
      return nil if count.zero?

      "#{count} #{'message'.pluralize(count)} could not be read"
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
    # (a) inquiries from the last 24 hours with a phone and no call yet,
    #     newest first, so a fresh inquiry is always on top;
    # (b) leads with a phone whose calls never connected (Attempted,
    #     Voicemail, or No answer) and that are due another try (attempt 2
    #     due 1 day after attempt 1; attempt 3 due 2 days after attempt 2; at
    #     most 3 attempts). The ad-lead routine counts CallLog.unanswered_attempts
    #     instead (outbound Voicemail or No answer, one per day, since the
    #     latest response or restore), retries daily, and gets varied
    #     time-of-day guidance;
    # (c) Re-contact leads whose date has arrived, with no call logged since
    #     that date and no open scheduled call, earliest date first;
    # (d) older uncalled inquiries up to 14 days old, oldest first.
    # Calls logged before CALL_CADENCE_STARTS_ON belong to the separate
    # backlog call sheet: such a lead stays off the list until a new call
    # starts its cadence.
    # Outside the ad-lead routine, a cadence is the run of calls within 14
    # days before the latest call; the routine's count is the same one its
    # Re-contact move uses, so it also includes backlog-sheet calls and calls
    # older than 14 days. Either way a lead leaves the list once its latest
    # call is over 14 days old.
    # Leads drop off once a call connects, they are marked Not interested,
    # Re-contact (until the re-contact date), spam or archived, have a
    # scheduled call, or have used 3 attempts. An open call booked on a
    # client also takes that client's open inquiries off.
    # Leads flagged as suspected spam stay on the list for a check.
    def call_entries
      @call_entries ||= begin
        window_start = @now - CALL_LIST_WINDOW
        cadence_start = CALL_CADENCE_STARTS_ON.in_time_zone
        recently_called = ActivityEvent.where(subject_type: "Lead", kind: "call")
          .where("activity_events.subject_id = leads.id").where("activity_events.occurred_at >= ?", [ window_start, cadence_start ].max)
        booked_clients = ScheduledCall.visible.scheduled.where.not(client_id: nil).select(:client_id)
        unbooked = Lead.where.not(id: ScheduledCall.scheduled.where.not(lead_id: nil).select(:lead_id))
          .where("leads.existing_client_id IS NULL OR leads.existing_client_id NOT IN (#{booked_clients.to_sql})")
        candidates = Lead.open
          .where(not_interested_marked_at: nil, recontact_marked_at: nil, spam_marked_at: nil)
          .where("TRIM(COALESCE(leads.phone, '')) <> '' OR TRIM(COALESCE(leads.phone_raw, '')) <> ''")
          .where("(leads.status = 'new' AND COALESCE(leads.received_at, leads.created_at) >= ?) OR EXISTS (#{recently_called.select(:id).to_sql})", window_start)
          .merge(unbooked)
          .includes(:tags)
          .to_a
        due_recontacts = Lead.recontact.where("leads.recontact_on <= ?", @today)
          .merge(unbooked)
          .includes(:tags)
          .to_a
        calls_by_lead = ActivityEvent.where(subject_type: "Lead", kind: "call", subject_id: (candidates + due_recontacts).map(&:id))
          .order(:occurred_at, :id).group_by(&:subject_id)

        fresh = []
        retries = []
        older = []

        candidates.each do |lead|
          waited_since = lead.received_at || lead.created_at
          calls = calls_by_lead.fetch(lead.id, []).select { |event| event.occurred_at >= waited_since }
          backlog_calls, calls = calls.partition { |event| event.occurred_at < cadence_start }

          if calls.empty?
            next unless backlog_calls.empty? && lead.status == "new" && waited_since >= window_start

            entry = CallEntry.new(
              lead: lead,
              attempt: 1,
              attempt_label: ATTEMPT_LABELS.fetch(1),
              last_call: nil,
              waited_since: waited_since,
              suggested_window: nil
            )
            (waited_since >= @now - FRESH_INQUIRY_WITHIN ? fresh : older) << entry
            next
          end

          last_call = calls.last
          next if last_call.occurred_at < window_start

          routine = lead.ad_call_routine?
          if routine
            cadence = CallLog.unanswered_attempts(lead)
            next if cadence.empty? && calls.any? { |call| call_connected?(call) }
          else
            cadence = calls.select { |call| call.occurred_at >= last_call.occurred_at - CALL_LIST_WINDOW }
            next if cadence.any? { |call| call_connected?(call) }
          end
          next if cadence.size >= MAX_CALL_ATTEMPTS

          attempt = cadence.size + 1
          days_wait = attempt == 2 || routine ? 1 : 2
          last_try = cadence.last
          due = last_try.nil? || last_try.occurred_at <= @now - days_wait.days ||
            last_try.occurred_at.in_time_zone.to_date <= @today - days_wait.days
          next unless due

          retries << CallEntry.new(
            lead: lead,
            attempt: attempt,
            attempt_label: ATTEMPT_LABELS.fetch(attempt),
            last_call: last_call,
            waited_since: waited_since,
            suggested_window: (CallLog.suggested_time_window(cadence) if routine)
          )
        end

        recontacts = due_recontacts.filter_map do |lead|
          due_since = lead.recontact_on.in_time_zone.beginning_of_day
          calls = calls_by_lead.fetch(lead.id, [])
          next if calls.any? { |call| call.occurred_at >= due_since }

          CallEntry.new(lead: lead, attempt: 1, attempt_label: RECONTACT_LABEL, last_call: calls.last, waited_since: due_since)
        end

        fresh.sort_by! { |entry| [ -entry.waited_since.to_f, -entry.lead.id ] }
        retries.sort_by! { |entry| [ entry.attempt, entry.last_call.occurred_at, entry.waited_since, entry.lead.id ] }
        recontacts.sort_by! { |entry| [ entry.waited_since, entry.lead.id ] }
        older.sort_by! { |entry| [ entry.waited_since, entry.lead.id ] }
        fresh + retries + recontacts + older
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
      @missed_calls ||= ScheduledCall.visible.missed(@now).includes(:client, lead: :tags).to_a
    end

    def todays_calls
      @todays_calls ||= ScheduledCall.visible.scheduled.for_day(@today)
        .where("scheduled_calls.scheduled_at >= ?", @now).includes(:client, lead: :tags).to_a
    end

    def upcoming_calls
      @upcoming_calls ||= ScheduledCall.visible.upcoming(@now).includes(:client, lead: :tags).to_a
    end

    def later_upcoming_calls
      @later_upcoming_calls ||= ScheduledCall.visible.scheduled
        .where("scheduled_calls.scheduled_at > ?", @today.in_time_zone.end_of_day)
        .order(scheduled_at: :asc, id: :asc).includes(:client, lead: :tags).to_a
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
          .includes(:client, :lead).to_a
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
