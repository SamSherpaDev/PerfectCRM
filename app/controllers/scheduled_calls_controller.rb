class ScheduledCallsController < ApplicationController
  before_action :set_scheduled_call, only: %i[update destroy complete cancel]

  def create
    lead_id = params[:lead_id].presence || params.dig(:scheduled_call, :lead_id).presence
    @lead = Lead.find(lead_id)
    if @lead.converted? || @lead.archived?
      return redirect_to return_destination(@lead), alert: "Calls can only be scheduled for active, unconverted leads."
    end

    @scheduled_call = @lead.scheduled_calls.build(scheduled_call_params)
    if @scheduled_call.save
      redirect_to return_destination(@lead),
        notice: "Call scheduled with #{@lead.name} for #{format_call_stamp(@scheduled_call)}."
    else
      redirect_to return_destination(@lead),
        alert: @scheduled_call.errors.full_messages.to_sentence.presence || "Enter a valid Pacific date and time."
    end
  end

  def update
    @lead = @scheduled_call.lead
    @scheduled_call.reschedule!(scheduled_call_params)
    redirect_to return_destination(@lead),
      notice: "Call with #{@lead.name} rescheduled for #{format_call_stamp(@scheduled_call)}."
  rescue ActiveRecord::RecordInvalid => e
    redirect_to return_destination(@lead),
      alert: e.record.errors.full_messages.to_sentence.presence || "Could not reschedule call."
  end

  def complete
    @lead = @scheduled_call.lead
    outcome = params[:outcome].presence || params.dig(:scheduled_call, :outcome).presence || "connected"
    notes = params[:notes].presence || params.dig(:scheduled_call, :notes).presence
    event = @scheduled_call.complete!(
      outcome: outcome,
      direction: params[:direction].presence || "outbound",
      duration: params[:duration].presence,
      save_key: params[:save_key].presence,
      notes: notes
    )
    label = CallLog::LABELS.fetch(event.metadata["outcome"], event.metadata["outcome"].to_s.humanize)
    redirect_to return_destination(@lead), notice: "Call logged: #{label}."
  rescue ActiveRecord::RecordInvalid, ArgumentError => e
    message = e.respond_to?(:record) ? e.record.errors.full_messages.to_sentence : e.message
    redirect_to return_destination(@lead), alert: message.presence || "Could not complete call."
  end

  def cancel
    @lead = @scheduled_call.lead
    @scheduled_call.cancel!
    redirect_to return_destination(@lead), notice: "Scheduled call with #{@lead.name} cancelled."
  rescue ActiveRecord::RecordInvalid => e
    redirect_to return_destination(@lead),
      alert: e.record.errors.full_messages.to_sentence.presence || "Could not cancel call."
  end

  alias_method :destroy, :cancel

  private

  def set_scheduled_call
    scope = params[:lead_id].present? ? Lead.find(params[:lead_id]).scheduled_calls : ScheduledCall.all
    @scheduled_call = scope.find(params[:id])
  end

  def scheduled_call_params
    source = if params[:scheduled_call].is_a?(ActionController::Parameters)
      params.require(:scheduled_call)
    else
      params
    end
    permitted = source.permit(:scheduled_on, :scheduled_time, :scheduled_at, :duration_minutes, :notes)
    permitted[:duration_minutes] = 30 if permitted[:duration_minutes].blank?
    permitted
  end

  def format_call_stamp(call)
    time = call.scheduled_at.in_time_zone
    "#{time.strftime('%a, %b %-d')} at #{time.strftime('%-I:%M %p %Z')}"
  end

  def return_destination(lead)
    safe_return_path(params[:return_to], lead) ||
      safe_return_path(request.referer, lead) ||
      lead_path(lead)
  end

  def safe_return_path(raw_value, lead)
    return nil if raw_value.blank?

    uri = URI.parse(raw_value.to_s)
    path = uri.path.to_s
    pairs = URI.decode_www_form(uri.query.to_s).to_h

    if path == root_path
      view = %w[week month].include?(pairs["view"]) ? pairs["view"] : nil
      date = valid_iso_date(pairs["date"])
      return root_path({ view: view, date: date }.compact)
    end

    if path == leads_path
      return nil unless (pairs.keys - %w[tab q sort]).empty?
      return nil if pairs["tab"].present? && !LeadsController::TABS.include?(pairs["tab"])
      return nil if pairs["sort"].present? && !%w[activity name newest fit].include?(pairs["sort"])

      return leads_path(pairs)
    end

    if lead && path == lead_path(lead)
      nested_return = safe_leads_only_path(pairs["return_to"])
      return lead_path(lead, { return_to: nested_return }.compact)
    end

    nil
  rescue URI::InvalidURIError, ArgumentError
    nil
  end

  def safe_leads_only_path(raw_value)
    return nil if raw_value.blank?

    uri = URI.parse(raw_value.to_s)
    return nil unless uri.relative? && uri.host.nil? && uri.path == leads_path

    pairs = URI.decode_www_form(uri.query.to_s).to_h
    tab = LeadsController::TABS.include?(pairs["tab"]) ? pairs["tab"] : nil
    sort = %w[activity name newest fit].include?(pairs["sort"]) ? pairs["sort"] : nil
    q = pairs["q"].to_s.strip.presence
    leads_path({ tab: tab, q: q, sort: sort }.compact)
  rescue URI::InvalidURIError, ArgumentError
    nil
  end

  def valid_iso_date(value)
    return nil if value.blank?

    Date.iso8601(value.to_s).iso8601
  rescue ArgumentError
    nil
  end
end
