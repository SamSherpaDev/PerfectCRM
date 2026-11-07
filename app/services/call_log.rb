# A reminder completing is not a connected call. Each deliberate call save
# carries a stable UUID, scoped to its inquiry, so double taps are harmless.
module CallLog
  OUTCOMES = %w[attempted connected voicemail no_answer].freeze
  UNANSWERED_OUTCOMES = %w[voicemail no_answer].freeze
  DIRECTIONS = %w[inbound outbound].freeze
  # What the captain sees, in button order; "Talked" is the stored `connected`.
  LABELS = { "connected" => "Talked", "voicemail" => "Voicemail", "no_answer" => "No answer", "attempted" => "Attempted" }.freeze
  ONE_TAP = %w[connected voicemail no_answer].freeze
  NOT_INTERESTED_CONFIRM = "This lead is marked not interested. Log an outbound call anyway?"
  AUTO_RECONTACT_CALLS = 3
  AUTO_RECONTACT_SUMMARY = "Moved to Re-contact automatically after three unanswered calls"
  AUTO_NOT_INTERESTED_SUMMARY = "Moved to Not interested automatically after three unanswered calls"
  REPLIED_AFTER_AUTO_MOVE_SUMMARY = "Moved back to Unsure: they replied after the automatic move."
  TIME_WINDOWS = %w[morning afternoon evening].freeze
  # Approved wording; the captain copies, edits, and sends it by hand.
  MISSED_CALL_TEXT = "Hi {{first_name}}, this is Sam at SherpaHolidays. I just tried giving you a quick call about your trip inquiry. " \
    "When is a good time for us to connect by phone, or is text easier for you?"
  MISSED_CALL_TEXT_NO_NAME = "Hi, this is Sam at SherpaHolidays. I just tried giving you a quick call about your trip inquiry. " \
    "When is a good time for us to connect by phone, or is text easier for you?"
  module_function

  def record!(record, key:, occurred_at:, outcome:, direction:, duration: nil, video_source: nil)
    raise ArgumentError, "Calls need an inquiry" unless record.is_a?(Lead)
    raise ArgumentError, "Invalid call" unless key.to_s.match?(/\A[\w-]{8,64}\z/) &&
      OUTCOMES.include?(outcome) && DIRECTIONS.include?(direction) && occurred_at && occurred_at <= Time.current + 5.minutes
    seconds = duration.present? ? Integer(duration) : nil
    raise ArgumentError, "Invalid duration" if seconds && !seconds.between?(0, 86_400)
    video = video_source.to_s.strip.first(240).presence

    record.with_lock do
      existing = record.activity_events.find_by(kind: "call", idempotency_key: key)
      call_meta = {
        "inquiry_id" => record.id,
        "direction" => direction,
        "outcome" => outcome,
        "duration_seconds" => seconds,
        "owner" => Current.user_email,
        "source_answer_event_id" => record.activity_events.where(kind: "source_answer").order(:id).last&.id
      }
      call_meta["video_source"] = video if video.present?
      event = existing ||
        record.activity_events.create!(kind: "call", idempotency_key: key,
          summary: "Call: #{LABELS.fetch(outcome)}", occurred_at: occurred_at,
          metadata: call_meta)
      if video.present? && !record.converted?
        record.update!(metadata: (record.metadata.is_a?(Hash) ? record.metadata : {}).merge("video_source" => video))
      end
      record.record_touch!(at: event.occurred_at) if event.metadata["outcome"] == "connected"
      if (client = record.converted_client || record.existing_client)
        client.activity_events.where(kind: "call").find_by("json_extract(metadata, '$.from_lead_event_id') = ?", event.id) ||
          client.activity_events.create!(kind: "call", idempotency_key: "#{record.id}:#{key}", summary: event.summary,
            occurred_at: event.occurred_at, metadata: event.metadata.merge("from_lead_id" => record.id, "from_lead_event_id" => event.id))
      end
      yield event if block_given?
      inbound = event.metadata["direction"] == "inbound"
      if existing.nil? && (inbound || event.metadata["outcome"] == "connected")
        if record.recontact? && !three_unanswered_calls?(record)
          restore_automatic_recontact!(record, inbound ? "they called" : "they answered a call")
        end
      elsif existing.nil? && UNANSWERED_OUTCOMES.include?(event.metadata["outcome"])
        move_after_three_unanswered_calls!(record, event: event)
      end
      event
    end
  end

  def time_window(moment)
    return nil if moment.blank?

    hour = moment.in_time_zone.hour
    if hour < 12
      "morning"
    elsif hour < 17
      "afternoon"
    else
      "evening"
    end
  end

  def suggested_time_window(prior_calls)
    tried = Array(prior_calls).filter_map do |call|
      moment = call.respond_to?(:occurred_at) ? call.occurred_at : call
      time_window(moment)
    end
    return "morning" if tried.empty?

    unused = TIME_WINDOWS - tried
    return unused.first if unused.any?

    TIME_WINDOWS[(TIME_WINDOWS.index(tried.last).to_i + 1) % TIME_WINDOWS.size]
  end

  def notice(event, with_text: false)
    lead = event.subject
    moved = if lead.recontact? && lead.activity_events.exists?(kind: "recontact", idempotency_key: event.idempotency_key)
      " Moved to Re-contact after three unanswered calls."
    elsif lead.not_interested? && lead.activity_events.exists?(kind: "not_interested", idempotency_key: event.idempotency_key)
      " Moved to Not interested after three unanswered calls."
    end
    logged = "Call logged: #{LABELS.fetch(event.metadata['outcome'])}.#{moved}"
    reminder = missed_call_reminder(lead, event)
    return logged unless reminder

    "#{logged} Send a short text by hand. #{reminder}#{" Suggested text: #{missed_call_text(lead)}" if with_text}"
  end

  def missed_call_text(lead)
    first_name = lead.name.to_s.split.first
    first_name ? MISSED_CALL_TEXT.sub("{{first_name}}", first_name) : MISSED_CALL_TEXT_NO_NAME
  end

  def missed_call_reminder(lead, call)
    return unless call && lead.ad_call_routine?

    attempts = unanswered_attempts(lead)
    return unless attempts.last == call

    if lead.recontact?
      return unless lead.recontact_on

      if call.occurred_at >= lead.recontact_on.in_time_zone.beginning_of_day
        "Re-contact follow-up missed · set a new date 3 or 6 months out or choose Restore from Re-contact."
      elsif !lead.recontact_due?
        "On the Re-contact list until #{lead.recontact_on.strftime('%b %-d, %Y')}."
      end
    elsif attempts.size < AUTO_RECONTACT_CALLS
      "Attempt #{attempts.size} of #{AUTO_RECONTACT_CALLS} logged · try attempt #{attempts.size + 1} next day in the #{suggested_time_window(attempts)}."
    else
      "#{attempts.size} unanswered attempts logged."
    end
  end

  # Outbound unanswered calls since the latest response or restore, oldest
  # first, at most AUTO_RECONTACT_CALLS. The ad-lead routine counts one
  # attempt per CRM-local day, keeping that day's latest call.
  def unanswered_attempts(record)
    attempts = record.activity_events.where(kind: "call")
      .where("json_extract(metadata, '$.outcome') IN (?) AND json_extract(metadata, '$.direction') = 'outbound'", UNANSWERED_OUTCOMES)
      .order(occurred_at: :desc, id: :desc)
      .to_a.lazy
      .take_while { |call| !responded_since?(record, call) }
    attempts = attempts.uniq { |call| call.occurred_at.in_time_zone.to_date } if record.ad_call_routine?
    attempts.first(AUTO_RECONTACT_CALLS).reverse
  end

  def three_unanswered_calls?(record)
    unanswered_attempts(record).size == AUTO_RECONTACT_CALLS
  end

  def responded_since?(record, first_call)
    reset_event = record.activity_events
      .where("kind IN ('interested_again', 'recontact_restored') OR (kind = 'call' AND (json_extract(metadata, '$.outcome') = 'connected' " \
        "OR json_extract(metadata, '$.direction') = 'inbound'))")
      .where("occurred_at > ? OR (occurred_at = ? AND id > ?)",
        first_call.occurred_at, first_call.occurred_at, first_call.id)
      .exists?
    return true if reset_event

    inbound = Message.inbound
      .where("COALESCE(messages.sent_at, messages.inbound_received_at, messages.created_at) > ?", first_call.occurred_at)
    inbound.where(conversation_id: Conversation.where(linkable: [ record, record.existing_client ].compact).select(:id))
      .or(inbound.where("LOWER(TRIM(messages.from_address)) IN (?)", record.current_recipient_emails))
      .any? { |message| Mail::ReplyAlerts.reply?(message.from_address, message.subject, message.inquiry_headers) }
  end

  def move_after_three_unanswered_calls!(record, event: nil)
    if record.ad_lead?
      mark_recontact_after_three_unanswered_calls!(record, event: event)
    else
      mark_not_interested_after_three_unanswered_calls!(record, event: event)
    end
  end

  def mark_recontact_after_three_unanswered_calls!(record, event: nil)
    return false unless record.recontact_eligible? && three_unanswered_calls?(record)

    record.mark_recontact!
    record.activity_events.create!(
      kind: "recontact",
      idempotency_key: event&.idempotency_key,
      summary: AUTO_RECONTACT_SUMMARY,
      occurred_at: [ Time.current, event&.occurred_at ].compact.max,
      metadata: {
        "reason" => "three_unanswered_calls",
        "call_event_id" => event&.id,
        "recontact_on" => record.recontact_on&.iso8601,
        "actor" => Current.user_email.presence || "automatic"
      }.compact
    )
    true
  end

  def mark_not_interested_after_three_unanswered_calls!(record, event: nil)
    return false unless record.unsure? && three_unanswered_calls?(record)

    record.mark_not_interested!
    record.activity_events.create!(
      kind: "not_interested",
      idempotency_key: event&.idempotency_key,
      summary: AUTO_NOT_INTERESTED_SUMMARY,
      occurred_at: [ Time.current, event&.occurred_at ].compact.max,
      metadata: {
        "reason" => "three_unanswered_calls",
        "call_event_id" => event&.id,
        "actor" => Current.user_email.presence || "automatic"
      }.compact
    )
    true
  end

  def backfill_unanswered_not_interested!
    moved = 0
    Lead.unsure.find_each do |lead|
      lead.with_lock do
        moved += 1 if mark_not_interested_after_three_unanswered_calls!(lead)
      end
    end
    moved
  end

  def restore_automatic_recontact!(lead, reason)
    move = lead.activity_events.where(kind: "recontact").order(:id).last
    return false unless lead.recontact? && move && lead.recontact_marked_at <= move.created_at

    place = if lead.unsure_marked_at.present? then "Unsure"
    elsif lead.status == "quoted" then "Quoted"
    else "New"
    end
    lead.unmark_recontact!(summary: "Moved back to #{place}: #{reason} after the automatic move.", actor: "automatic")
    true
  end

  def restore_after_reply!(message)
    sender = message.from_address.to_s.strip.downcase
    Lead.recontact.where(email: sender)
      .or(Lead.recontact.where(id: Person.where(email: sender).select(:lead_id)))
      .find_each do |lead|
        lead.with_lock { restore_automatic_recontact!(lead, "they replied") }
      end
    Lead.not_interested.where(email: sender)
      .or(Lead.not_interested.where(id: Person.where(email: sender).select(:lead_id)))
      .find_each do |lead|
        lead.with_lock do
          move = lead.activity_events.where(kind: "not_interested").order(:id).last
          next unless lead.not_interested? && move && lead.not_interested_marked_at <= move.created_at

          lead.unmark_not_interested!(summary: REPLIED_AFTER_AUTO_MOVE_SUMMARY, actor: "automatic")
        end
      end
  end
end
