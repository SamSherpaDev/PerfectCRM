class CallsController < ApplicationController
  def create
    record = params[:client_id].present? ? Client.find(params[:client_id]) : Lead.find(params[:lead_id])
    inquiry = if record.is_a?(Client)
      Lead.where(converted_client_id: record.id).or(Lead.where(existing_client_id: record.id)).find(params[:inquiry_id])
    else
      record
    end
    back = polymorphic_path(record, anchor: "record-details")
    return redirect_to back, alert: "Restore this record before logging a call." if record.archived?

    # One-tap buttons send no time: the call happened now.
    occurred_at = params[:occurred_at].present? ? Time.zone.parse(params[:occurred_at].to_s) : Time.current
    event = CallLog.record!(inquiry, key: params[:save_key], occurred_at: occurred_at,
      outcome: params[:outcome], direction: params[:direction], duration: params[:duration])
    ScheduledCall.complete_due_by!(event)
    redirect_to back, notice: "Call logged: #{CallLog::LABELS.fetch(event.metadata['outcome'])}."
  rescue ArgumentError, TypeError
    redirect_to back, alert: "Check the call time, outcome and duration."
  end
end
