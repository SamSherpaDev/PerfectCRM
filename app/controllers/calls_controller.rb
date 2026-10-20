class CallsController < ApplicationController
  def create
    record = params[:client_id].present? ? Client.find(params[:client_id]) : Lead.find(params[:lead_id])
    inquiry = if record.is_a?(Client)
      Lead.where(converted_client_id: record.id).or(Lead.where(existing_client_id: record.id)).find(params[:inquiry_id])
    else
      record
    end
    back = safe_today_return_path || polymorphic_path(record, anchor: "record-details")
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

  private

  def safe_today_return_path
    raw = params[:return_to].to_s
    return if raw.blank?

    uri = URI.parse(raw)
    return unless uri.relative? && uri.host.nil? && uri.path == root_path

    query = URI.decode_www_form(uri.query.to_s).to_h
    view = query["view"] if %w[week month].include?(query["view"])
    date = Date.iso8601(query["date"]).iso8601 if query["date"].present?
    root_path({ view: view, date: date }.compact)
  rescue URI::InvalidURIError, ArgumentError
    nil
  end
end
