class ScheduledCallsController < ApplicationController
  include LeadsReturnPath
  include TodayReturnPath

  before_action :set_lead
  before_action :set_scheduled_call, only: %i[update complete cancel]

  def create
    @scheduled_call = @lead.scheduled_calls.build(scheduled_call_params)
    if @scheduled_call.save
      redirect_to return_destination,
        notice: "Call scheduled with #{@lead.name} for #{format_call_stamp(@scheduled_call)}."
    else
      redirect_to return_destination,
        alert: @scheduled_call.errors.full_messages.to_sentence.presence || "Enter a valid Pacific date and time."
    end
  end

  def update
    @scheduled_call.reschedule!(scheduled_call_params)
    redirect_to return_destination,
      notice: "Call with #{@lead.name} rescheduled for #{format_call_stamp(@scheduled_call)}."
  rescue ActiveRecord::RecordInvalid => e
    redirect_to return_destination,
      alert: e.record.errors.full_messages.to_sentence.presence || "Could not reschedule call."
  end

  def complete
    event = @scheduled_call.complete!(outcome: params[:outcome], save_key: params[:save_key])
    redirect_to return_destination, notice: "Call logged: #{CallLog::LABELS.fetch(event.metadata['outcome'])}."
  rescue ActiveRecord::RecordInvalid => e
    redirect_to return_destination,
      alert: e.record.errors.full_messages.to_sentence.presence || "Could not complete call."
  rescue ArgumentError
    redirect_to return_destination, alert: "Could not complete call."
  end

  def cancel
    @scheduled_call.cancel!
    redirect_to return_destination, notice: "Scheduled call with #{@lead.name} cancelled."
  rescue ActiveRecord::RecordInvalid => e
    redirect_to return_destination,
      alert: e.record.errors.full_messages.to_sentence.presence || "Could not cancel call."
  end

  private

  def set_lead
    @lead = Lead.find(params[:lead_id])
  end

  def set_scheduled_call
    @scheduled_call = @lead.scheduled_calls.find(params[:id])
  end

  def scheduled_call_params
    params.require(:scheduled_call).permit(:scheduled_on, :scheduled_time, :duration_minutes, :notes)
  end

  def format_call_stamp(call)
    time = call.scheduled_at.in_time_zone
    "#{time.strftime('%a, %b %-d')} at #{time.strftime('%-I:%M %p %Z')}"
  end

  def return_destination
    value = params[:return_to].to_s
    safe_leads_return_path(value) || safe_today_return_path(value) || safe_lead_return_path(value) || lead_path(@lead)
  end

  def safe_lead_return_path(value)
    uri = URI.parse(value)
    return unless uri.relative? && uri.host.nil? && uri.path == lead_path(@lead)

    nested = URI.decode_www_form(uri.query.to_s).to_h["return_to"]
    lead_path(@lead, { return_to: safe_leads_return_path(nested) }.compact)
  rescue URI::InvalidURIError, ArgumentError
    nil
  end
end
