# Everything the Today view and the morning digest need, in one place.
#
# Waiting-on-you threads and quotes-out counts await their Today integration
# (marked TODO below); see README.md, "Today and follow-ups".
# Departure windows read the mirrored PerfectBook bookings.
module Today
  class Summary
    DEPARTING_WITHIN = 14.days
    RETURNED_WITHIN = 7.days

    def initialize(today: Date.current)
      @today = today
    end
    # Inbound threads newer than the last outbound.
    # TODO(mail-in): read from the Conversation/Message models once they land.
    def waiting_on_you
      0
    end

    # TODO(mail-in): the actual threads waiting for a reply.
    def replies_waiting
      []
    end

    # TODO(quotes): wire the existing Quote model into this count.
    def quotes_out
      0
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
  end
end
