# Every lead stage change goes through here so the automation boundary
# holds in one place: automations (n8n, Panda AI) may only set new,
# chatting, or lost. Quoted, nudged, and conversion to won stay manual.
# Stage changes record ActivityEvents and notify Tasks::OnStageChange.
# That service owns which stages propose follow-up tasks.
class Leads::Transition
  Result = Data.define(:record, :from, :to, :converted_client)

  AUTOMATION_ONLY_ERROR = "Automations may only set new, chatting, or lost. Quoted, nudged, and won stay yours."

  def self.call(lead, to:, actor: :captain, lost_reason: nil, lost_note: nil, attributes: {}, expected_client_id: "new")
    new(lead, to.to_s, actor.to_sym, lost_reason, lost_note, attributes, expected_client_id).call
  end

  def initialize(lead, to, actor, lost_reason, lost_note, attributes, expected_client_id)
    @attributes = attributes
    @expected_client_id = expected_client_id
    @lead = lead
    @to = to
    @actor = actor
    @lost_reason = lost_reason.to_s.strip.presence
    @lost_note = lost_note.to_s.strip.presence
  end

  def call
    from = @lead.converted? ? "converted" : @lead.status
    raise ActiveRecord::RecordInvalid, @lead if @lead.converted?

    @lead.errors.clear

    if @lead.archived?
      @lead.errors.add(:base, "Archived leads stay read-only until restored.")
      raise ActiveRecord::RecordInvalid, @lead
    end

    if @actor == :automation && !Lead::AUTOMATION_STATUSES.include?(@to)
      @lead.errors.add(:status, AUTOMATION_ONLY_ERROR)
      raise ActiveRecord::RecordInvalid, @lead
    end

    if @to == "won"
      if @actor == :automation
        @lead.errors.add(:status, AUTOMATION_ONLY_ERROR)
        raise ActiveRecord::RecordInvalid, @lead
      end
      client = @lead.convert_to_client!(expected_client_id: @expected_client_id)
      notify_tasks(@lead, from: from, to: "won")
      return Result.new(record: @lead, from: from, to: "won", converted_client: client)
    end

    unless Lead::STATUSES.include?(@to)
      @lead.errors.add(:status, "is not a lead stage")
      raise ActiveRecord::RecordInvalid, @lead
    end

    @lead.with_lock do
      @lead.assign_attributes(@attributes)
      @lead.status = @to
      @lead.stage_changed_at = Time.current
      if @to == "lost"
        @lead.lost_reason = @lost_reason
        @lead.lost_note = @lost_note
      else
        @lead.lost_reason = nil
        @lead.lost_note = nil
      end
      @lead.save!
      metadata = { "from" => from, "to" => @to, "actor" => @actor.to_s }
      metadata["lost_reason"] = @lead.lost_reason if @actor == :captain
      ActivityEvent.create!(
        subject: @lead,
        kind: "stage_change",
        summary: "Moved from #{from.humanize} to #{@to.humanize}",
        occurred_at: Time.current,
        metadata: metadata
      )
    end
    notify_tasks(@lead, from: from, to: @to)
    Result.new(record: @lead, from: from, to: @to, converted_client: nil)
  end

  private

  def notify_tasks(record, from:, to:)
    return unless defined?(Tasks::OnStageChange)

    Tasks::OnStageChange.call(subject: record, from: from, to: to)
  end
end
