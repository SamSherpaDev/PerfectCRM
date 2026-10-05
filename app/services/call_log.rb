# A reminder completing is not a connected call. Each deliberate call save
# carries a stable UUID, scoped to its inquiry, so double taps are harmless.
module CallLog
  OUTCOMES = %w[attempted connected voicemail no_answer].freeze
  DIRECTIONS = %w[inbound outbound].freeze
  module_function

  def record!(record, key:, occurred_at:, outcome:, direction:, duration: nil)
    raise ArgumentError, "Calls need an inquiry" unless record.is_a?(Lead)
    raise ArgumentError, "Invalid call" unless key.to_s.match?(/\A[\w-]{8,64}\z/) &&
      OUTCOMES.include?(outcome) && DIRECTIONS.include?(direction) && occurred_at && occurred_at <= Time.current + 5.minutes
    seconds = duration.present? ? Integer(duration) : nil
    raise ArgumentError, "Invalid duration" if seconds && !seconds.between?(0, 86_400)

    record.with_lock do
      event = record.activity_events.find_by(kind: "call", idempotency_key: key) ||
        record.activity_events.create!(kind: "call", idempotency_key: key,
          summary: "Call: #{outcome.humanize}", occurred_at: occurred_at,
          metadata: { "inquiry_id" => record.id, "direction" => direction, "outcome" => outcome,
            "duration_seconds" => seconds, "owner" => Current.user_email,
            "source_answer_event_id" => record.activity_events.where(kind: "source_answer").order(:id).last&.id })
      record.record_touch!(at: event.occurred_at) if event.metadata["outcome"] == "connected"
      if (client = record.converted_client || record.existing_client)
        client.activity_events.where(kind: "call").find_by("json_extract(metadata, '$.from_lead_event_id') = ?", event.id) ||
          client.activity_events.create!(kind: "call", idempotency_key: "#{record.id}:#{key}", summary: event.summary,
            occurred_at: event.occurred_at, metadata: event.metadata.merge("from_lead_id" => record.id, "from_lead_event_id" => event.id))
      end
      event
    end
  end
end
