# Copy and small decisions for the lead and client record pages
# (app/views/records). Layout: README.md, "Leads" and "Clients".
module RecordsHelper
  # One sentence under the name: where the ask came from and what it is.
  def record_subtitle(record)
    if record.archived?
      suffix = record.is_a?(Lead) ? " Restore to work this lead again." : ""
      return "Archived on #{date_short(record.archived_at)}.#{suffix}"
    end
    if record.is_a?(Lead)
      return "Became a client on #{date_short(record.converted_at)}. Converted leads stay read-only." if record.converted?

      parts = [ lead_source_label(record), record.trip_interest.presence || record.trip_title.presence,
                lead_party_and_when(record) ]
      parts.compact_blank.join(" · ")
    else
      record.display_email.presence || "No email on file yet."
    end
  end

  # "Lead · New" with the stage as a badge; archived records read plainly.
  def record_eyebrow(record)
    noun = record.is_a?(Lead) ? "Lead" : "Client"
    return "#{noun} · Archived" if record.archived?

    stage = if record.is_a?(Lead)
      status_badge(record.converted? ? "converted" : record.status)
    else
      stage_badge(record.pipeline_stage)
    end
    safe_join([ noun, " ", stage ])
  end

  # "2 travelers · October 2026", "Timing unknown", or nil when the form said nothing.
  def lead_party_and_when(lead)
    parts = []
    parts << pluralize(lead.party_size, "traveler") if lead.party_size.present?
    if lead.timing_unknown?
      parts << "Timing unknown"
    elsif lead.travel_month.present? || lead.travel_year.present?
      parts << [ (Date::MONTHNAMES[lead.travel_month] if lead.travel_month), lead.travel_year ].compact.join(" ")
    end
    parts.join(" · ").presence
  end

  # Meta time on a timeline stone: the clock today, the date otherwise.
  def timeline_stamp(time)
    return "" if time.blank?

    time = time.in_time_zone
    if time.to_date == Date.current
      "Today #{time.strftime('%H:%M')}"
    else
      "#{date_short(time)} · #{time.strftime('%H:%M')}"
    end
  end

  # Who an inbound stone is from: the record's own name when the address is theirs.
  def timeline_sender(message, record)
    address = message.from_address.to_s
    own = [ record.try(:email), record.try(:display_email) ].compact_blank.map(&:downcase)
    own.include?(address.downcase) ? record.name : address
  end

  # A stone that landed in the last few seconds settles onto the stream.
  def timeline_row_class(kind, at)
    classes = [ "ev", kind.to_s ]
    classes << "ev-new" if at.present? && at > 15.seconds.ago
    classes.join(" ")
  end

  # Timeline stone kind for an activity event: quote-ish outlined, PerfectBook
  # outlined blue, automation dashed.
  def event_stone_kind(event)
    case event.kind
    when "automation" then "auto"
    when /booking|perfectbook|document|payment/ then "pb"
    else "q"
    end
  end

  EVENT_ACTORS = {
    "conversion" => "Converted", "stage_change" => "Stage", "quote" => "Quote",
    "task" => "Follow-up", "email" => "Email"
  }.freeze

  def event_actor(event)
    return automation_caller(event).presence || "Automation" if event.kind == "automation"

    EVENT_ACTORS.fetch(event.kind, event.kind.to_s.humanize)
  end

  # Second line under an Upcoming title.
  def upcoming_day_tile(date, warn: false)
    tag.span(class: "date-tile#{' due' if warn}", aria: { hidden: true }) do
      safe_join([ tag.b(date.strftime("%-d")), tag.small(date.strftime("%b")) ])
    end
  end
end
