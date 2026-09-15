# Quote builder and tracker. Quotes are built from the mirrored
# PerfectBook catalog (never the API directly), sent as email plus PDF, and
# accepted through the public tap-to-accept page.
class QuotesController < ApplicationController
  before_action :set_quote, only: %i[show edit update send_quote duplicate revise]

  TAB_ICONS = { "draft" => :pencil, "sent" => :mail, "accepted" => :check,
                "expired" => :history }.freeze

  def index
    @tab = Quote::TABS.include?(params[:tab]) ? params[:tab] : "draft"
    @counts = {
      "draft" => Quote.where(status: "draft").count,
      "sent" => Quote.where(status: %w[sent viewed]).count,
      "accepted" => Quote.where(status: "accepted").count,
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
    submitted = params[:quote].present? ? quote_params : {}
    if @trip && submitted[:perfectbook_trip_id].blank? && submitted[:included].blank? && params[:included_edited] != "1"
      submitted = submitted.except(:included)
    end
    @quote = Quote.new({
      perfectbook_trip_id: @trip&.perfectbook_id,
      trip_name: @trip&.name,
      party_size: 2,
      valid_until: Date.current + 14,
      included: QuoteTripPreference.find_by(perfectbook_trip_id: @trip&.perfectbook_id)&.included
    }.merge(submitted).merge(owner_params))
    @quote.perfectbook_trip_id = @trip&.perfectbook_id
    prefill_lines
    3.times { @quote.lines.build(quantity: 1) }
  end

  def create
    @owner = find_owner
    return redirect_to quotes_path, alert: "Pick a client or lead first." unless @owner

    @quote = Quote.new(quote_params.merge(owner_params))
    if apply_catalog_snapshot && @quote.save
      remember_inclusions
      if params[:send_now].present?
        send_saved_quote
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
    load_catalog_options
  end

  def update
    @quote.with_lock do
      unless @quote.draft?
        redirect_to @quote, alert: "Only drafts can be edited. Make a revision instead."
        next
      end

      @quote.assign_attributes(quote_params)
      catalog_changed = @quote.perfectbook_trip_id_changed? || @quote.perfectbook_departure_id_changed?
      if (!catalog_changed || apply_catalog_snapshot(replace_description: true)) && @quote.save
        remember_inclusions
        if params[:send_now].present?
          send_saved_quote
        else
          redirect_to @quote, notice: "Quote saved."
        end
      else
        load_catalog_options
        render :edit, status: :unprocessable_entity
      end
    end
  end

  def send_quote
    send_saved_quote
  end

  def duplicate
    copy = @quote.duplicate!
    redirect_to copy, notice: "Quote duplicated as #{copy.reference}."
  end

  def revise
    revision = @quote.new_revision!
    return redirect_to @quote, alert: "This quote can no longer be revised." unless revision

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

  def prefill_lines
    departure = @departures.find_by(perfectbook_id: params[:departure_id]) if @trip && params[:departure_id].present?
    @quote.perfectbook_departure_id = departure&.perfectbook_id
    if @trip && @quote.lines.none? { |line| %w[trip departure].include?(line.kind) }
      @prefilled_unit = Quote.last_unit_for_trip(@trip.perfectbook_id, departure_id: @quote.perfectbook_departure_id)
      @quote.lines.build(kind: "trip", description: [ @trip.name, departure && departure_label(departure) ].compact.join(" - "),
        quantity: @quote.party_size.presence || 2, unit_minor: @prefilled_unit.to_i)
    end
    apply_catalog_snapshot(replace_description: true)
  end

  def apply_catalog_snapshot(replace_description: false)
    trip = PerfectBook::Trip.find_by(perfectbook_id: @quote.perfectbook_trip_id) if @quote.perfectbook_trip_id.present?
    departure = PerfectBook::Departure.find_by(perfectbook_id: @quote.perfectbook_departure_id) if @quote.perfectbook_departure_id.present?
    if (@quote.perfectbook_trip_id.present? && !trip) ||
        (@quote.perfectbook_departure_id.present? && (!departure || departure.perfectbook_trip_id != trip&.perfectbook_id))
      @quote.errors.add(:base, "Choose a departure belonging to the selected trip.")
      return false
    end

    previous_catalog_description = [ @quote.trip_name, @quote.departure_label ].compact_blank.join(" - ")
    @quote.trip_name = trip&.name if trip || replace_description
    @quote.departure_label = departure && departure_label(departure)
    @quote.departure_start_on = departure&.start_date
    @quote.departure_end_on = departure&.end_date
    @quote.lines.each do |line|
      next if line.marked_for_destruction? || !%w[trip departure].include?(line.kind)

      line.kind = trip ? (departure ? "departure" : "trip") : "custom"
      line.perfectbook_trip_id = trip&.perfectbook_id
      line.snapshot_trip_name = trip&.name
      line.perfectbook_departure_id = departure&.perfectbook_id
      line.snapshot_departure_label = @quote.departure_label
      line.snapshot_start_on = departure&.start_date
      line.snapshot_end_on = departure&.end_date
      if replace_description && trip && line.description == previous_catalog_description
        line.description = [ trip.name, @quote.departure_label ].compact.join(" - ")
      end
    end
    true
  end

  def load_catalog_options
    @trips = PerfectBook::Catalog.new.active_trips.or(PerfectBook::Trip.where(perfectbook_id: @quote.perfectbook_trip_id))
    @departures = PerfectBook::Departure.order(:start_date)
  end

  def remember_inclusions
    return unless params[:remember_inclusions] == "1" && @quote.perfectbook_trip_id.present?

    preference = QuoteTripPreference.find_or_initialize_by(perfectbook_trip_id: @quote.perfectbook_trip_id)
    preference.update!(included: @quote.included)
  end

  def departure_label(departure)
    if departure.start_date && departure.end_date
      "#{departure.start_date.strftime('%-d %b')} – #{departure.end_date.strftime('%-d %b %Y')}"
    else
      departure.label.presence || departure.place.presence || "Flexible dates"
    end
  end

  def send_saved_quote
    @quote.with_lock(requires_new: true) do
      unless @quote.deliver!
        if @quote.draft? && @quote.errors.any?
          load_catalog_options
          return render :edit, status: :unprocessable_entity
        end
        return redirect_to @quote, alert: "Only drafts with a line and an email can be sent."
      end

      job = QuoteMailer.quote_email(@quote).deliver_later
      raise ActiveJob::EnqueueError, "Quote email was not queued" unless job
    end
    redirect_to @quote, notice: "Quote sent with PDF and accept link."
  rescue ActiveJob::EnqueueError, SolidQueue::Job::EnqueueError => error
    Rails.logger.error("Quote #{@quote.reference} email enqueue failed: #{error.class}")
    redirect_to @quote, alert: "Quote saved as a draft. The email could not be queued. Please try sending again."
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
