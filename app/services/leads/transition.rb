# Every lead stage change goes through here so the automation boundary
# holds in one place: automations (n8n, Panda AI) may only set new,
# chatting, or lost. Quoted, nudged, and conversion to won stay manual.
# Stage changes record ActivityEvents and notify the tasks lane when it
# lands (Tasks::OnStageChange); until then the hook is a no-op.
class Leads::Transition
  Result = Data.define(:record, :from, :to, :converted_client)

  AUTOMATION_ONLY_ERROR = "Automations may only set new, chatting, or lost. Quoted, nudged, and won stay yours."
  LOST_REASON_ERROR = "Pick a reason. Every lost lead needs one."

  def self.call(lead, to:, actor: :captain, lost_reason: nil, lost_note: nil)
    new(lead, to.to_s, actor.to_sym, lost_reason, lost_note).call
  end

  def initialize(lead, to, actor, lost_reason, lost_note)
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

    if @actor == :automation && !Lead::AUTOMATION_STATUSES.include?(@to)
      @lead.errors.add(:status, AUTOMATION_ONLY_ERROR)
      raise ActiveRecord::RecordInvalid, @lead
    end

    if @to == "won"
      if @actor == :automation
        @lead.errors.add(:status, AUTOMATION_ONLY_ERROR)
        raise ActiveRecord::RecordInvalid, @lead
      end
      client = @lead.convert_to_client!
      notify_tasks(@lead, from: from, to: "won")
      return Result.new(record: @lead, from: from, to: "won", converted_client: client)
    end

    unless Lead::STATUSES.include?(@to)
      @lead.errors.add(:status, "is not a lead stage")
      raise ActiveRecord::RecordInvalid, @lead
    end

    if @to == "lost" && @lost_reason.blank?
      @lead.errors.add(:lost_reason, LOST_REASON_ERROR)
      raise ActiveRecord::RecordInvalid, @lead
    end
    if @to == "lost" && !Lead::LOST_REASONS.include?(@lost_reason)
      @lead.errors.add(:lost_reason, "is not a known reason")
      raise ActiveRecord::RecordInvalid, @lead
    end

    @lead.with_lock do
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
      ActivityEvent.create!(
        subject: @lead,
        kind: "stage_change",
        summary: "Moved from #{from.humanize} to #{@to.humanize}",
        occurred_at: Time.current,
        metadata: { "from" => from, "to" => @to, "actor" => @actor.to_s }
      )
    end
    notify_tasks(@lead, from: from, to: @to)
    Result.new(record: @lead, from: from, to: @to, converted_client: nil)
  end

  private

  # TODO(tasks): replace with a real call once the tasks lane lands
  # Tasks::OnStageChange. Until then this is intentionally a no-op.
  def notify_tasks(record, from:, to:)
    return unless defined?(Tasks::OnStageChange)

    Tasks::OnStageChange.call(record, from: from, to: to)
  end
end
