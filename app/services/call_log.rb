# A reminder completing is not a connected call. Each deliberate call save
# carries a stable UUID, scoped to its inquiry, so double taps are harmless.
module CallLog
  OUTCOMES = %w[attempted connected voicemail no_answer].freeze
  DIRECTIONS = %w[inbound outbound].freeze
  # What the captain sees, in button order; "Talked" is the stored `connected`.
  LABELS = { "connected" => "Talked", "voicemail" => "Voicemail", "no_answer" => "No answer", "attempted" => "Attempted" }.freeze
  ONE_TAP = %w[connected voicemail no_answer].freeze
  NOT_INTERESTED_CONFIRM = "This lead is marked not interested. Log an outbound call anyway?"
  AUTO_NOT_INTERESTED_VOICEMAILS = 3
  AUTO_NOT_INTERESTED_SUMMARY = "Moved to Not interested automatically after three voicemails"
  REPLIED_AFTER_AUTO_MOVE_SUMMARY = "Moved back to Unsure: they replied after the automatic move."
  module_function

  def record!(record, key:, occurred_at:, outcome:, direction:, duration: nil)
    raise ArgumentError, "Calls need an inquiry" unless record.is_a?(Lead)
    raise ArgumentError, "Invalid call" unless key.to_s.match?(/\A[\w-]{8,64}\z/) &&
      OUTCOMES.include?(outcome) && DIRECTIONS.include?(direction) && occurred_at && occurred_at <= Time.current + 5.minutes
    seconds = duration.present? ? Integer(duration) : nil
    raise ArgumentError, "Invalid duration" if seconds && !seconds.between?(0, 86_400)

    record.with_lock do
      existing = record.activity_events.find_by(kind: "call", idempotency_key: key)
      event = existing ||
        record.activity_events.create!(kind: "call", idempotency_key: key,
          summary: "Call: #{LABELS.fetch(outcome)}", occurred_at: occurred_at,
          metadata: { "inquiry_id" => record.id, "direction" => direction, "outcome" => outcome,
            "duration_seconds" => seconds, "owner" => Current.user_email,
            "source_answer_event_id" => record.activity_events.where(kind: "source_answer").order(:id).last&.id })
      record.record_touch!(at: event.occurred_at) if event.metadata["outcome"] == "connected"
      if (client = record.converted_client || record.existing_client)
        client.activity_events.where(kind: "call").find_by("json_extract(metadata, '$.from_lead_event_id') = ?", event.id) ||
          client.activity_events.create!(kind: "call", idempotency_key: "#{record.id}:#{key}", summary: event.summary,
            occurred_at: event.occurred_at, metadata: event.metadata.merge("from_lead_id" => record.id, "from_lead_event_id" => event.id))
      end
      yield event if block_given?
      if existing.nil? && event.metadata.values_at("outcome", "direction") == %w[voicemail outbound]
        mark_not_interested_after_three_voicemails!(record, event: event)
      end
      event
    end
  end

  def notice(event)
    lead = event.subject
    moved = lead.not_interested? &&
      lead.activity_events.exists?(kind: "not_interested", idempotency_key: event.idempotency_key)
    "Call logged: #{LABELS.fetch(event.metadata['outcome'])}.#{' Moved to Not interested after three voicemails.' if moved}"
  end

  def three_unanswered_voicemails?(record)
    recent_voicemails = record.activity_events.where(kind: "call")
      .where("json_extract(metadata, '$.outcome') = 'voicemail' AND json_extract(metadata, '$.direction') = 'outbound'")
      .order(occurred_at: :desc, id: :desc)
      .limit(AUTO_NOT_INTERESTED_VOICEMAILS)
      .to_a
    return false unless recent_voicemails.size == AUTO_NOT_INTERESTED_VOICEMAILS

    !responded_since?(record, recent_voicemails.last)
  end

  def responded_since?(record, first_voicemail)
    reset_event = record.activity_events
      .where("kind = 'interested_again' OR (kind = 'call' AND (json_extract(metadata, '$.outcome') = 'connected' " \
        "OR json_extract(metadata, '$.direction') = 'inbound'))")
      .where("occurred_at > ? OR (occurred_at = ? AND id > ?)",
        first_voicemail.occurred_at, first_voicemail.occurred_at, first_voicemail.id)
      .exists?
    return true if reset_event

    inbound = Message.inbound
      .where("COALESCE(messages.sent_at, messages.inbound_received_at, messages.created_at) > ?", first_voicemail.occurred_at)
    inbound.where(conversation_id: Conversation.where(linkable: [ record, record.existing_client ].compact).select(:id))
      .or(inbound.where("LOWER(TRIM(messages.from_address)) IN (?)", record.current_recipient_emails))
      .any? { |message| Mail::ReplyAlerts.reply?(message.from_address, message.subject, message.inquiry_headers) }
  end

  def mark_not_interested_after_three_voicemails!(record, event: nil)
    return unless record.unsure? && three_unanswered_voicemails?(record)

    record.mark_not_interested!
    record.activity_events.create!(
      kind: "not_interested",
      idempotency_key: event&.idempotency_key,
      summary: AUTO_NOT_INTERESTED_SUMMARY,
      occurred_at: [ Time.current, event&.occurred_at ].compact.max,
      metadata: {
        "reason" => "three_voicemails",
        "call_event_id" => event&.id,
        "actor" => Current.user_email.presence || "automatic"
      }.compact
    )
  end

  def restore_after_reply!(message)
    sender = message.from_address.to_s.strip.downcase
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
