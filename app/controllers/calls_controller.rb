class CallsController < ApplicationController
  include ListReturnPath
  include TodayReturnPath

  def create
    record = params[:client_id].present? ? Client.find(params[:client_id]) : Lead.find(params[:lead_id])
    inquiry = record.is_a?(Client) ? record.inquiries.find(params[:inquiry_id]) : record
    back = safe_today_return_path(params[:return_to].to_s) || record_path_keeping_list(record, anchor: "record-details")
    return redirect_to back, alert: "Restore this record before logging a call." if record.archived?

    # One-tap buttons send no time: the call happened now.
    occurred_at = params[:occurred_at].present? ? Time.zone.parse(params[:occurred_at].to_s) : Time.current
    event = CallLog.record!(inquiry, key: params[:save_key], occurred_at: occurred_at,
      outcome: params[:outcome], direction: params[:direction], duration: params[:duration]) do |logged_event|
      ScheduledCall.complete_due_by!(logged_event)
    end
    redirect_to back, notice: "Call logged: #{CallLog::LABELS.fetch(event.metadata['outcome'])}."
  rescue ArgumentError, TypeError
    redirect_to back, alert: "Check the call time, outcome and duration."
  end
end
