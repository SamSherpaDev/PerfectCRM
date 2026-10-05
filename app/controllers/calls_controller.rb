class CallsController < ApplicationController
  def create
    record = params[:client_id].present? ? Client.find(params[:client_id]) : Lead.find(params[:lead_id])
    inquiry = if record.is_a?(Client)
      Lead.where(converted_client_id: record.id).or(Lead.where(existing_client_id: record.id)).find(params[:inquiry_id])
    else
      record
    end
    return redirect_to record, alert: "Restore this record before logging a call." if record.archived?

    CallLog.record!(inquiry, key: params[:save_key], occurred_at: Time.zone.parse(params[:occurred_at].to_s),
      outcome: params[:outcome], direction: params[:direction], duration: params[:duration])
    redirect_to record, notice: "Call saved."
  rescue ArgumentError, TypeError
    redirect_to record, alert: "Check the call time, outcome and duration."
  end
end
