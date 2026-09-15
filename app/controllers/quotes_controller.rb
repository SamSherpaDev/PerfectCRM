# Quote builder and tracker. Quotes are built from the mirrored
# PerfectBook catalog (never the API directly), sent as email plus PDF, and
# accepted through the public tap-to-accept page.
class QuotesController < ApplicationController
  before_action :set_quote, only: %i[show edit update send_quote duplicate revise]

  TAB_ICONS = { "draft" => :pencil, "sent" => :mail, "accepted" => :check,
                "declined" => :close, "expired" => :history }.freeze

  def index
    @tab = Quote::TABS.include?(params[:tab]) ? params[:tab] : "draft"
    @counts = {
      "draft" => Quote.where(status: "draft").count,
      "sent" => Quote.where(status: %w[sent viewed]).count,
      "accepted" => Quote.where(status: "accepted").count,
      "declined" => Quote.where(status: "declined").count,
      "expired" => Quote.expired.count
    }
    @quotes = Quote.for_tab(@tab).ordered.includes(:client, :lead, :lines)
  end

  def show
    @revisions = @quote.revisions.ordered.includes(:client, :lead)
    respond_to do |format|
      format.html
      format.pdf do
        send_data QuotePdf.new(@quote, accept_url: public_quote_url(@quote.accept_token)).render,
          filename: "quote-#{@quote.reference}.pdf", type: "application/pdf",
          disposition: "attachment"
      end
    end
  end

  def new
    @owner = find_owner
    return redirect_to quotes_path, alert: "Pick a client or lead first." unless @owner

    @trips = PerfectBook::Catalog.new.active_trips
    @trip = @trips.find_by(perfectbook_id: params[:trip_id]) if params[:trip_id].present?
    @departures = @trip ? PerfectBook::Catalog.new.departures_for_trip(@trip.perfectbook_id).limit(30) : []
    @quote = Quote.new(owner_params.merge(
      perfectbook_trip_id: @trip&.perfectbook_id,
      trip_name: @trip&.name,
      party_size: 2,
      valid_until: 14.days.from_now.to_date,
      included: default_included
    ))
    prefill_lines
    3.times { @quote.lines.build(quantity: 1) }
  end

  def create
    @owner = find_owner
    return redirect_to quotes_path, alert: "Pick a client or lead first." unless @owner

    @quote = Quote.new(quote_params.merge(owner_params))
    apply_departure_snapshot
    if @quote.save
      if params[:send_now].present?
        send_and_redirect
      else
        redirect_to @quote, notice: "Quote saved as a draft."
      end
    else
      @trips = PerfectBook::Catalog.new.active_trips
      @departures = []
      render :new, status: :unprocessable_entity
    end
  end

  def edit
    redirect_to(@quote, alert: "Only drafts can be edited. Make a revision instead.") and return unless @quote.draft?
  end

  def update
    redirect_to(@quote, alert: "Only drafts can be edited. Make a revision instead.") and return unless @quote.draft?

    if @quote.update(quote_params)
      if params[:send_now].present?
        send_saved_quote
      else
        redirect_to @quote, notice: "Quote saved."
      end
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def send_quote
    unless @quote.sendable?
      return redirect_to @quote, alert: "Add at least one line and make sure they have an email first."
    end

    @quote.deliver!
    QuoteMailer.quote_email(@quote).deliver_later
    redirect_to @quote, notice: "Quote sent with PDF and accept link."
  end

  def duplicate
    copy = @quote.duplicate!
    redirect_to copy, notice: "Quote duplicated as #{copy.reference}."
  end

  def revise
    revision = @quote.new_revision!
    redirect_to edit_quote_path(revision), notice: "Revision #{revision.reference} started. The old version keeps its history."
  end

  private

  def set_quote
    @quote = Quote.includes(:lines, :client, :lead).find(params[:id])
  end

  def find_owner
    if params[:client_id].present?
      Client.find_by(id: params[:client_id])
    elsif params[:lead_id].present?
      Lead.find_by(id: params[:lead_id])
    elsif params.dig(:quote, :client_id).present?
      Client.find_by(id: params.dig(:quote, :client_id))
    elsif params.dig(:quote, :lead_id).present?
      Lead.find_by(id: params.dig(:quote, :lead_id))
    end
  end

  def owner_params
    case @owner
    when Client then { client: @owner }
    when Lead then { lead: @owner }
    else {}
    end
  end

  # Prices are entered by the captain: PerfectBook has no catalog price, so
  # prefill the trip line from the newest earlier quote for the same trip.
  def prefill_lines
    return unless @trip

    unit = Quote.last_unit_for_trip(@trip.perfectbook_id, kind: "trip")
    departure_id = params[:departure_id].presence
    if departure_id
      departure = PerfectBook::Departure.find_by(perfectbook_id: departure_id,
        perfectbook_trip_id: @trip.perfectbook_id)
      if departure
        @quote.perfectbook_departure_id = departure.perfectbook_id
        @quote.departure_label = departure_label(departure)
        @quote.departure_start_on = departure.start_date
        @quote.departure_end_on = departure.end_date
        @quote.lines.build(kind: "departure", description: "#{@trip.name} — #{departure_label(departure)}",
          quantity: @quote.party_size.to_i.positive? ? @quote.party_size.to_i : 2,
          unit_minor: unit.to_i, perfectbook_trip_id: @trip.perfectbook_id,
          perfectbook_departure_id: departure.perfectbook_id,
          snapshot_trip_name: @trip.name, snapshot_departure_label: departure_label(departure),
          snapshot_start_on: departure.start_date, snapshot_end_on: departure.end_date)
        return
      end
    end
    @quote.lines.build(kind: "trip", description: @trip.name,
      quantity: 2, unit_minor: unit.to_i, perfectbook_trip_id: @trip.perfectbook_id,
      snapshot_trip_name: @trip.name)
  end

  def apply_departure_snapshot
    return if @quote.perfectbook_departure_id.blank?

    departure = PerfectBook::Departure.find_by(perfectbook_id: @quote.perfectbook_departure_id)
    return unless departure

    trip = PerfectBook::Trip.find_by(perfectbook_id: departure.perfectbook_trip_id)
    @quote.trip_name ||= trip&.name || departure.trip_name
    @quote.perfectbook_trip_id ||= departure.perfectbook_trip_id
    @quote.departure_label ||= departure_label(departure)
    @quote.departure_start_on ||= departure.start_date
    @quote.departure_end_on ||= departure.end_date
    @quote.lines.each do |line|
      next unless %w[trip departure].include?(line.kind)

      line.perfectbook_trip_id ||= @quote.perfectbook_trip_id
      line.snapshot_trip_name ||= @quote.trip_name
      if line.kind == "departure"
        line.perfectbook_departure_id ||= departure.perfectbook_id
        line.snapshot_departure_label ||= @quote.departure_label
        line.snapshot_start_on ||= departure.start_date
        line.snapshot_end_on ||= departure.end_date
      end
    end
  end

  def departure_label(departure)
    if departure.start_date && departure.end_date
      "#{departure.start_date.strftime('%-d %b')} – #{departure.end_date.strftime('%-d %b %Y')}"
    else
      departure.label.presence || departure.place.presence || "Flexible dates"
    end
  end

  def default_included
    "Guided trek with an experienced Sherpa guide, teahouse lodges, " \
      "all permits, and ground transfers in Nepal."
  end

  def send_and_redirect
    send_saved_quote
  end

  def send_saved_quote
    unless @quote.sendable?
      return redirect_to @quote, alert: "Quote saved as a draft. Add a line and an email to send it."
    end

    @quote.deliver!
    QuoteMailer.quote_email(@quote).deliver_later
    redirect_to @quote, notice: "Quote sent with PDF and accept link."
  end

  def quote_params
    params.require(:quote).permit(
      :party_size, :trip_name, :departure_label, :departure_start_on, :departure_end_on,
      :perfectbook_trip_id, :perfectbook_departure_id, :notes, :included,
      :deposit_dollars, :balance_due_on, :valid_until,
      lines_attributes: %i[id kind description quantity unit_dollars _destroy]
    )
  end
end
