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

    def initialize(now: Time.current, today: now.to_date)
      @today = today
      @now = now
    end
    # Threads still needing a personal response (automatic greetings do not clear them).
    def waiting_on_you
      waiting_threads.count
    end

    def replies_waiting
      waiting_threads.limit(5).to_a
    end

    def unlinked_inquiries
      @unlinked_inquiries ||= begin
        resolve_unlinked_inquiries!
        inquiry_scanner.messages
      end
    end

    # Sent or viewed quotes whose valid-until has not passed.
    def quotes_out
      Quote.live.where.not(id: Quote.expired.select(:id))
        .where.not(id: Quote.where(lead_id: Lead.archived.select(:id)).select(:id)).count
    end

    # New stage alone does not establish whether an inquiry has been worked.
    def new_leads
      resolve_unlinked_inquiries!
      Lead.by_status("new").count
    end

    # One full weekday without a successful personal reply or logged call.
    # Keep this separate from replies owed: it includes inquiries with no email
    # thread, and handling an inquiry once removes it even if more mail arrives.
    def not_yet_called
      since_inquiry = "COALESCE(leads.received_at, leads.created_at)"
      replied = Message.personal_replies.where(status: %w[sent received])
        .joins(:conversation).where(conversations: { linkable_type: "Lead" })
        .where("conversations.linkable_id = leads.id AND messages.sent_at >= #{since_inquiry}")
      called = ActivityEvent.where(subject_type: "Lead", kind: "call")
        .where("activity_events.subject_id = leads.id AND occurred_at >= #{since_inquiry}")

      Lead.by_status("new").where("#{since_inquiry} < ?", one_business_day_ago)
        .where("NOT EXISTS (#{replied.select(:id).to_sql})")
        .where("NOT EXISTS (#{called.select(:id).to_sql})")
        .order(Arel.sql("#{since_inquiry} ASC, leads.id ASC"))
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

    private

    def one_business_day_ago
      as_of = @now
      # Freeze elapsed business time at Saturday midnight throughout the weekend.
      as_of = as_of.beginning_of_week(:monday) + 5.days if as_of.saturday? || as_of.sunday?
      cutoff = as_of - 1.day
      cutoff -= 1.day while cutoff.saturday? || cutoff.sunday?
      cutoff
    end

    def waiting_threads
      resolve_unlinked_inquiries!
      Conversation.where(ignored: false).ordered.preload(:linkable, :messages)
        .merge(Conversation.waiting_on_you).linked
    end

    def inquiry_scanner
      @inquiry_scanner ||= Leads::UnlinkedInquiries.new(now: @now)
    end

    def resolve_unlinked_inquiries!
      return if @resolved_unlinked_inquiries

      @resolved_unlinked_inquiries = true
      inquiry_scanner.resolve! if inquiry_scanner.respond_to?(:resolve!)
    end
  end
end
