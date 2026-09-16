# Everything the Today view and the morning digest need, in one place.
#
# Waiting-on-you threads mirror the Inbox "Waiting on you" tab (linked
# owners only; unknown senders wait in triage). Quotes-out counts live
# sent and viewed quotes whose valid-until has not passed.
# New leads and active clients reuse the models' own vocabulary: the New
# stage of Lead::STATUSES, and every client that is not archived.
# Departure windows read the mirrored PerfectBook bookings.
module Today
  class Summary
    DEPARTING_WITHIN = 14.days
    RETURNED_WITHIN = 7.days

    def initialize(today: Date.current)
      @today = today
    end
    # Inbound threads newer than the last outbound.
    def waiting_on_you
      waiting_threads.count
    end

    def replies_waiting
      waiting_threads.limit(5).to_a
    end

    # Sent or viewed quotes whose valid-until has not passed.
    def quotes_out
      Quote.live.where.not(id: Quote.expired.select(:id)).count
    end

    # Leads still sitting in the New stage, nobody has worked them yet.
    def new_leads
      Lead.by_status("new").count
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
      PerfectBook::Booking
        .where(start_date: @today..@today + DEPARTING_WITHIN)
        .order(:start_date, :id)
    end

    # Back from the mountains: the departure ended within the last 7 days.
    def returned
      PerfectBook::Booking
        .where(end_date: (@today - RETURNED_WITHIN)..@today)
        .order(:end_date, :id)
    end

    def subject_for(booking)
      Tasks::Automatic.subject_for(booking)
    end

    private

    def waiting_threads
      Conversation.where(ignored: false).ordered.preload(:linkable, :messages)
        .merge(Conversation.waiting_on_you).linked
    end
  end
end
