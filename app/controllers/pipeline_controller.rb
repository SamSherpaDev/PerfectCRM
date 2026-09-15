class PipelineController < ApplicationController
  STAGE_LABELS = {
    "new" => "New", "chatting" => "Chatting", "quoted" => "Quoted",
    "nudged" => "Nudged", "won" => "Won", "post_trip" => "Post-trip",
    "lost" => "Lost"
  }.freeze

  def show
    @board = Pipeline::Board.new(
      source: params[:source], trip: params[:trip], advisor: params[:advisor]
    )
    @columns = @board.columns
    @report = Pipeline::Report.new
    @filters = @board.filters
    @lost_lead = Lead.find_by(id: params[:lost_lead_id]) if params[:lost_lead_id].present?
  end

  # Drag-drop and Move-menu target. Leads move through Transition (which
  # enforces the automation boundary); clients move between won and
  # post_trip. Moving a lead to won converts it; moving to lost needs a
  # reason, collected by the lost sheet.
  def move
    if params[:client_id].present?
      move_client
    else
      move_lead
    end
  end

  private

  def move_lead
    lead = Lead.find(params[:lead_id])
    to = params[:to].to_s
    if lead.converted?
      return redirect_to pipeline_path(filter_params), alert: "Converted leads stay read-only."
    end
    if to == "won"
      return redirect_to lead_path(lead), notice: "Review the client before converting."
    end
    Leads::Transition.call(lead, to: to, actor: :captain,
      lost_reason: params[:lost_reason], lost_note: params[:lost_note])
    redirect_to pipeline_path(filter_params), notice: "Moved to #{STAGE_LABELS.fetch(to, to)}."
  rescue ActiveRecord::RecordNotFound
    redirect_to pipeline_path(filter_params), alert: "That lead is gone."
  rescue ActiveRecord::RecordInvalid => e
    redirect_to pipeline_path(filter_params.merge(lost_lead_id: lead.id)),
      alert: e.record.errors.full_messages.to_sentence.presence || "Could not move."
  end

  def move_client
    client = Client.find(params[:client_id])
    to = params[:to].to_s
    unless Client::PIPELINE_STAGES.include?(to)
      return redirect_to pipeline_path(filter_params), alert: "Clients move between Won and Post-trip."
    end
    from = client.pipeline_stage
    client.update!(pipeline_stage: to)
    ActivityEvent.create!(
      subject: client, kind: "stage_change",
      summary: "Moved from #{from.humanize} to #{to.humanize}",
      occurred_at: Time.current, metadata: { "from" => from, "to" => to, "actor" => "captain" }
    )
    redirect_to pipeline_path(filter_params), notice: "Moved to #{STAGE_LABELS.fetch(to, to)}."
  rescue ActiveRecord::RecordNotFound
    redirect_to pipeline_path(filter_params), alert: "That client is gone."
  rescue ActiveRecord::RecordInvalid => e
    redirect_to pipeline_path(filter_params),
      alert: e.record.errors.full_messages.to_sentence.presence || "Could not move."
  end

  def filter_params
    params.permit(:source, :trip, :advisor).to_h.compact_blank
  end
  helper_method :filter_params
end
