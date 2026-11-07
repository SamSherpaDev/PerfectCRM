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
  AUTO_NOT_INTERESTED_CALLS = AUTO_RECONTACT_CALLS
  AUTO_RECONTACT_SUMMARY = "Moved to Re-contact automatically after three unanswered calls"
  AUTO_NOT_INTERESTED_SUMMARY = "Moved to Not interested automatically after three unanswered calls"
  REPLIED_AFTER_AUTO_MOVE_SUMMARY = "Moved back to Unsure: they replied after the automatic move."
  TIME_WINDOWS = %w[morning afternoon evening].freeze
  MISSED_CALL_TEXT_TEMPLATE = "Hi {{first_name}}, this is Sam from Sherpa Holidays. Sorry I missed you just now - I wanted to follow up on {{trip_context}}. When is a good time for a quick call, or feel free to text me back here?"
  module_function

  def record!(record, key:, occurred_at:, outcome:, direction:, duration: nil, video_source: nil)
    raise ArgumentError, "Calls need an inquiry" unless record.is_a?(Lead)
    raise ArgumentError, "Invalid call" unless key.to_s.match?(/\A[\w-]{8,64}\z/) &&
      OUTCOMES.include?(outcome) && DIRECTIONS.include?(direction) && occurred_at && occurred_at <= Time.current + 5.minutes
    seconds = duration.present? ? Integer(duration) : nil
    raise ArgumentError, "Invalid duration" if seconds && !seconds.between?(0, 86_400)
    video = video_source.to_s.strip.presence
    raise ArgumentError, "Invalid video source" if video && video.length > 240

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
      if existing.nil? && event.metadata["direction"] == "outbound" && UNANSWERED_OUTCOMES.include?(event.metadata["outcome"])
        mark_recontact_after_three_unanswered_calls!(record, event: event)
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

  def missed_call_text_draft(lead)
    first_name = lead&.name.to_s.strip.split(/\s+/).first.presence || "there"
    trip = lead&.trip_interest.to_s.strip.presence || lead&.trip_title.to_s.strip.presence
    trip_context = trip ? "your #{trip} inquiry" : "your trip inquiry"
    MISSED_CALL_TEXT_TEMPLATE
      .sub("{{first_name}}", first_name)
      .sub("{{trip_context}}", trip_context)
  end

  def notice(event)
    lead = event.subject
    moved = lead.recontact? &&
      lead.activity_events.exists?(kind: "recontact", idempotency_key: event.idempotency_key)
    "Call logged: #{LABELS.fetch(event.metadata['outcome'])}.#{' Moved to Re-contact after three unanswered calls.' if moved}"
  end

  def three_unanswered_calls?(record)
    recent_calls = record.activity_events.where(kind: "call")
      .where("json_extract(metadata, '$.outcome') IN (?) AND json_extract(metadata, '$.direction') = 'outbound'", UNANSWERED_OUTCOMES)
      .order(occurred_at: :desc, id: :desc)
      .limit(AUTO_RECONTACT_CALLS)
      .to_a
    return false unless recent_calls.size == AUTO_RECONTACT_CALLS

    !responded_since?(record, recent_calls.last)
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

  def mark_recontact_after_three_unanswered_calls!(record, event: nil)
    return false unless record.unsure? && three_unanswered_calls?(record)

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

  # Retained for historical migration 20261101202153_move_unanswered_unsure_leads_to_not_interested.
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

  def restore_after_reply!(message)
    sender = message.from_address.to_s.strip.downcase
    Lead.recontact.where(email: sender)
      .or(Lead.recontact.where(id: Person.where(email: sender).select(:lead_id)))
      .find_each do |lead|
        lead.with_lock do
          move = lead.activity_events.where(kind: "recontact").order(:id).last
          next unless lead.recontact? && move && lead.recontact_marked_at <= move.created_at

          lead.unmark_recontact!(summary: REPLIED_AFTER_AUTO_MOVE_SUMMARY, actor: "automatic")
        end
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
