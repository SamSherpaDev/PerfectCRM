class ScheduledCallsController < ApplicationController
  include LeadsReturnPath
  include TodayReturnPath

  before_action :set_owner
  before_action :set_scheduled_call, only: %i[update complete cancel]

  def create
    @scheduled_call = @owner.scheduled_calls.build(scheduled_call_params)
    if @scheduled_call.save
      redirect_to return_destination,
        notice: "Call scheduled with #{@owner.name} for #{format_call_stamp(@scheduled_call)}."
    else
      redirect_to return_destination,
        alert: @scheduled_call.errors.full_messages.to_sentence.presence || "Enter a valid Pacific date and time."
    end
  end

  def update
    @scheduled_call.reschedule!(scheduled_call_params)
    redirect_to return_destination,
      notice: "Call with #{@owner.name} rescheduled for #{format_call_stamp(@scheduled_call)}."
  rescue ActiveRecord::RecordInvalid => e
    redirect_to return_destination,
      alert: e.record.errors.full_messages.to_sentence.presence || "Could not reschedule call."
  end

  def complete
    event = @scheduled_call.complete!(outcome: params[:outcome], save_key: params[:save_key], inquiry_id: params[:inquiry_id])
    redirect_to return_destination, notice: "Call logged: #{CallLog::LABELS.fetch(event.metadata['outcome'])}."
  rescue ActiveRecord::RecordInvalid => e
    redirect_to return_destination,
      alert: e.record.errors.full_messages.to_sentence.presence || "Could not complete call."
  rescue ArgumentError
    redirect_to return_destination, alert: "Could not complete call."
  end

  def cancel
    @scheduled_call.cancel!
    redirect_to return_destination, notice: "Scheduled call with #{@owner.name} cancelled."
  rescue ActiveRecord::RecordInvalid => e
    redirect_to return_destination,
      alert: e.record.errors.full_messages.to_sentence.presence || "Could not cancel call."
  end

  private

  def set_owner
    if params[:client_id].present?
      @client = Client.find(params[:client_id])
      @owner = @client
    else
      @lead = Lead.find(params[:lead_id])
      @owner = @lead
    end
  end

  def set_scheduled_call
    @scheduled_call = @owner.scheduled_calls.find(params[:id])
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
    safe_leads_return_path(value) || safe_clients_return_path(value) || safe_today_return_path(value) || safe_record_return_path(value) || polymorphic_path(@owner)
  end

  def safe_clients_return_path(value)
    return unless value.present?

    uri = URI.parse(value)
    return unless uri.relative? && uri.host.nil? && uri.path == clients_path && uri.fragment.nil?

    pairs = URI.decode_www_form(uri.query.to_s)
    return unless pairs.map(&:first).uniq.length == pairs.length
    return unless (pairs.map(&:first) - %w[tab q sort]).empty?

    query = pairs.to_h
    return if query["tab"].present? && !%w[clients organizations archived].include?(query["tab"])
    return if query["sort"].present? && !%w[activity name newest].include?(query["sort"])

    clients_path(query)
  rescue URI::InvalidURIError, ArgumentError
    nil
  end

  def safe_record_return_path(value)
    uri = URI.parse(value)
    target_path = polymorphic_path(@owner)
    return unless uri.relative? && uri.host.nil? && uri.path == target_path

    nested = URI.decode_www_form(uri.query.to_s).to_h["return_to"]
    safe_nested = @owner.is_a?(Client) ? safe_clients_return_path(nested) : safe_leads_return_path(nested)
    polymorphic_path(@owner, { return_to: safe_nested }.compact)
  rescue URI::InvalidURIError, ArgumentError
    nil
  end
end
