# Quote builder and tracker. Trip details come from the PerfectBook mirror
# and the published SherpaHolidays storefront. Quotes are sent as email plus
# PDF and accepted through the public tap-to-accept page.
class QuotesController < ApplicationController
  before_action :set_quote, only: %i[show edit update send_quote duplicate revise terms_intake]

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

  def terms_intake
    raise ActiveRecord::RecordNotFound unless @quote.status == "accepted"

    send_data JSON.pretty_generate(@quote.intake_details), type: "application/json",
      filename: "#{@quote.reference}-perfectbook-intake.json", disposition: "attachment"
  end

  def new
    @owner = find_owner
    return redirect_to quotes_path, alert: "Pick a client or lead first." unless @owner

    @trips = PerfectBook::Catalog.new.active_trips
    @trip = find_catalog_trip(params[:trip_id]) if params[:trip_id].present?
    if params[:trip_id].nil? && params[:quote].blank? && @owner.is_a?(Lead)
      interests = [ @owner.trip_interest, @owner.trip_title ].compact_blank.map(&:downcase)
      interests.each do |interest|
        @trip = @trips.where("lower(name) = ?", interest).first
        break if @trip
      end
      @trip ||= find_storefront_trip(handle: @owner.trip_handle) if @owner.trip_handle.present?
    end
    @departures = @trip&.perfectbook_id ? PerfectBook::Catalog.new.departures_for_trip(@trip.perfectbook_id).limit(30) : []
    submitted = params[:quote].present? ? quote_params : {}
    if @trip && submitted[:perfectbook_trip_id].blank? && submitted[:included].blank? && params[:included_edited] != "1"
      submitted = submitted.except(:included)
    end
    @quote = Quote.new({
      perfectbook_trip_id: @trip&.perfectbook_id,
      shopify_product_id: (@trip.shopify_product_id if @trip && @trip.perfectbook_id.nil?),
      trip_name: @trip&.name,
      party_size: (@owner.is_a?(Lead) ? @owner.party_size : nil).presence || 2,
      valid_until: Date.current + 14,
      included: QuoteTripPreference.find_by(perfectbook_trip_id: @trip&.perfectbook_id)&.included
    }.merge(submitted).merge(owner_params))
    @quote.perfectbook_trip_id = @trip&.perfectbook_id
    @quote.shopify_product_id = @trip && @trip.perfectbook_id.nil? ? @trip.shopify_product_id : nil
    prefill_lines
    load_trip_source(prefill: true)
    load_trip_choices
    3.times { @quote.lines.build(quantity: 1) }
  end

  def create
    @owner = find_owner
    return redirect_to quotes_path, alert: "Pick a client or lead first." unless @owner

    @quote = Quote.new(quote_params.merge(owner_params))
    if apply_catalog_snapshot && restore_catalog_source && @quote.save
      remember_inclusions
      if params[:send_now].present?
        send_saved_quote
      else
        redirect_to @quote, notice: "Quote saved as a draft."
      end
    else
      load_catalog_options
      render :new, status: :unprocessable_entity
    end
  end

  def edit
    redirect_to(@quote, alert: "Only drafts can be edited. Make a revision instead.") and return unless @quote.draft?
    load_catalog_options
  end

  def update
    send_after_update = false
    if params[:load_trip_source].present?
      candidate = @quote.dup
      candidate.assign_attributes(quote_params.except(:lines_attributes))
      begin
        trip, departure = selected_catalog_records(candidate)
        @reloaded_trip_source = QuoteCatalog.snapshot(trip: trip, departure: departure)
      rescue QuoteCatalog::Unavailable => error
        @catalog_warning = error.message
      end
    end
    @quote.with_lock do
      unless @quote.draft?
        redirect_to @quote, alert: "Only drafts can be edited. Make a revision instead."
        next
      end

      @quote.assign_attributes(quote_params)
      catalog_changed = @quote.perfectbook_trip_id_changed? || @quote.perfectbook_departure_id_changed? || @quote.shopify_product_id_changed?
      @quote.catalog_snapshot = nil if catalog_changed
      source_loaded = params[:load_trip_source].present? ? load_trip_source(prefill: true, replace: true) : restore_catalog_source
      if apply_catalog_snapshot(replace_description: catalog_changed) && source_loaded && @quote.save
        remember_inclusions
        if params[:load_trip_source].present?
          redirect_to edit_quote_path(@quote), notice: "Current trip details loaded. Review the itinerary, inclusions and price."
        elsif params[:send_now].present?
          send_after_update = true
        else
          redirect_to @quote, notice: "Quote saved."
        end
      else
        load_catalog_options
        render :edit, status: :unprocessable_entity
      end
    end
    send_saved_quote if send_after_update
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

  def find_storefront_trip(**options)
    QuoteCatalog.storefront_trip(**options)
  rescue QuoteCatalog::Unavailable => error
    @catalog_warning = error.message
    nil
  end

  def find_catalog_trip(choice)
    if choice.to_s.start_with?("shopify:")
      find_storefront_trip(product_id: choice.to_s.delete_prefix("shopify:"))
    else
      @trips.find_by(perfectbook_id: choice)
    end
  end

  def load_trip_choices
    @trip_choices = @trips.map { |trip| [ trip.name, trip.perfectbook_id ] }
    return unless params[:storefront] == "1" || @quote.shopify_product_id.present?

    mirrored_products = @trips.map { |trip| trip.shopify_product_id.to_s.split("/").last }
    QuoteCatalog.products.each do |product|
      next if mirrored_products.include?(product.fetch("id").to_s)

      @trip_choices << [ product.fetch("title"), "shopify:#{product.fetch('id')}" ]
    end
    @trip_choices.sort_by! { |name, _| name.downcase }
  rescue QuoteCatalog::Unavailable => error
    @catalog_warning = error.message
  end

  def selected_catalog_records(quote = @quote)
    trip = if quote.perfectbook_trip_id.present?
      PerfectBook::Trip.find_by(perfectbook_id: quote.perfectbook_trip_id)
    elsif quote.shopify_product_id.present?
      QuoteCatalog.storefront_trip(product_id: quote.shopify_product_id)
    end
    departure = PerfectBook::Departure.find_by(perfectbook_id: quote.perfectbook_departure_id)
    departure = nil unless departure&.perfectbook_trip_id == trip&.perfectbook_id
    [ trip, departure ]
  end

  def load_trip_source(prefill: false, replace: false)
    if replace && @catalog_warning
      @quote.errors.add(:base, @catalog_warning)
      return false
    end
    trip, departure = selected_catalog_records
    @quote.catalog_snapshot = replace ? @reloaded_trip_source : QuoteCatalog.snapshot(trip: trip, departure: departure)
    source = @quote.catalog_snapshot
    return true unless source && prefill

    if replace && @quote.lines.none? { |line| !line.marked_for_destruction? && %w[trip departure].include?(line.kind) }
      @quote.lines.build(kind: departure ? "departure" : "trip", description: trip.name,
        quantity: @quote.party_size.presence || 2, price_edited: "0")
    end

    if source["included"].present? && (replace || params[:included_edited] != "1")
      @quote.included = source["included"]
    end
    if source["itinerary"].present? && (replace || params[:itinerary_edited] != "1")
      @quote.itinerary = source["itinerary"]
    end
    if source["price_minor"].present?
      @quote.lines.each do |line|
        next unless !line.marked_for_destruction? && %w[trip departure].include?(line.kind) && (replace || line.price_edited == "0")

        line.unit_minor = source["price_minor"]
        line.price_edited = "0"
      end
      @prefilled_unit = nil
    end
    true
  rescue QuoteCatalog::Unavailable => error
    @catalog_warning = error.message
    if replace
      @quote.errors.add(:base, error.message)
      false
    else
      true
    end
  end

  def restore_catalog_source
    return true if params[:catalog_source_token].blank?

    source = Rails.application.message_verifier(:quote_catalog).verified(params[:catalog_source_token], purpose: :quote_catalog)
    unless source.is_a?(Hash)
      @quote.errors.add(:base, "Trip source could not be verified. Load trip details again.")
      return false
    end
    trip, = selected_catalog_records
    product_id = trip&.shopify_product_id.to_s.split("/").last.presence
    if source["trip_id"] == @quote.perfectbook_trip_id && source["departure_id"] == @quote.perfectbook_departure_id && source["shopify_product_id"] == product_id
      @quote.catalog_snapshot = source
    end
    true
  rescue QuoteCatalog::Unavailable => error
    @quote.errors.add(:base, error.message)
    false
  end

  def catalog_current_for_delivery?(current_source)
    trip, = selected_catalog_records
    return true unless @quote.catalog_snapshot.present? || current_source.present? || trip&.shopify_product_id.present?
    return true if @quote.catalog_snapshot.present? && QuoteCatalog.same_offer?(@quote.catalog_snapshot, current_source)

    @quote.errors.add(:base, "Trip details or prices have changed, or have not been loaded. Load current trip details and review before sending.")
    false
  end

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
    departure = @departures.find_by(perfectbook_id: params[:departure_id]) if @trip&.perfectbook_id && params[:departure_id].present?
    @quote.perfectbook_departure_id = departure&.perfectbook_id
    if @trip && @quote.lines.none? { |line| %w[trip departure].include?(line.kind) }
      @quote.lines.build(kind: "trip", description: [ @trip.name, departure && departure_label(departure) ].compact.join(" - "),
        quantity: @quote.party_size.presence || 2, price_edited: "0")
    end
    if @trip
      @quote.lines.select { |line| %w[trip departure].include?(line.kind) && line.price_edited == "0" }.each do |line|
        @prefilled_unit = Quote.last_unit_for_trip(@trip.perfectbook_id, departure_id: @quote.perfectbook_departure_id)
        line.unit_minor = @prefilled_unit.to_i
      end
    end
    apply_catalog_snapshot(replace_description: true)
  end

  def apply_catalog_snapshot(replace_description: false)
    trip, departure = selected_catalog_records
    if (@quote.perfectbook_trip_id.present? && !trip) ||
        (@quote.shopify_product_id.present? && !trip) ||
        (@quote.perfectbook_departure_id.present? && (!departure || departure.perfectbook_trip_id != trip&.perfectbook_id))
      @quote.errors.add(:base, "Choose a departure belonging to the selected trip.")
      return false
    end

    previous_catalog_description = [ @quote.trip_name, @quote.departure_label ].compact_blank.join(" - ")
    if trip
      @quote.trip_name = trip.name
      @quote.departure_label = departure && departure_label(departure)
      @quote.departure_start_on = departure.start_date if departure&.start_date.present?
      @quote.departure_end_on = departure.end_date if departure&.end_date.present?
    end
    @quote.lines.each do |line|
      next if line.marked_for_destruction? || !%w[trip departure].include?(line.kind)

      line.kind = trip ? (departure ? "departure" : "trip") : "custom"
      line.perfectbook_trip_id = trip&.perfectbook_id
      line.snapshot_trip_name = trip&.name
      line.perfectbook_departure_id = departure&.perfectbook_id
      line.snapshot_departure_label = @quote.departure_label
      line.snapshot_start_on = trip ? @quote.departure_start_on : nil
      line.snapshot_end_on = trip ? @quote.departure_end_on : nil
      if replace_description && trip && line.description == previous_catalog_description
        line.description = [ trip.name, @quote.departure_label ].compact.join(" - ")
      end
    end
    true
  rescue QuoteCatalog::Unavailable => error
    @quote.errors.add(:base, error.message)
    false
  end

  def load_catalog_options
    @trips = PerfectBook::Catalog.new.active_trips.or(PerfectBook::Trip.where(perfectbook_id: @quote.perfectbook_trip_id))
    @trip = find_catalog_trip(@quote.catalog_choice) if @quote.catalog_choice.present?
    @departures = if action_name == "create"
      @trip&.perfectbook_id ? PerfectBook::Catalog.new.departures_for_trip(@trip.perfectbook_id).limit(30) : []
    elsif @quote.shopify_product_id.present?
      []
    else
      PerfectBook::Departure.order(:start_date)
    end
    load_trip_choices
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
    trip, departure = selected_catalog_records
    current_source = QuoteCatalog.snapshot(trip: trip, departure: departure)
    @quote.with_lock(requires_new: true) do
      unless catalog_current_for_delivery?(current_source)
        load_catalog_options
        return render :edit, status: :unprocessable_entity
      end
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
  rescue QuoteCatalog::Unavailable => error
    @quote.errors.add(:base, "#{error.message} Review current trip details before sending.")
    load_catalog_options
    render :edit, status: :unprocessable_entity
  rescue ActiveJob::EnqueueError, SolidQueue::Job::EnqueueError => error
    Rails.logger.error("Quote #{@quote.reference} email enqueue failed: #{error.class}")
    redirect_to @quote, alert: "Quote saved as a draft. The email could not be queued. Please try sending again."
  end

  def quote_params
    attributes = params.require(:quote).permit(
      :party_size, :trip_name, :departure_label, :departure_start_on, :departure_end_on,
      :perfectbook_trip_id, :perfectbook_departure_id, :shopify_product_id, :notes, :included, :itinerary,
      :deposit_dollars, :balance_due_on, :valid_until,
      :journey_kind, :local_operator, :trip_differences,
      disclosure_details: [ *QuoteTerms::FIELDS.keys, :fund_notice ],
      lines_attributes: %i[id kind description quantity unit_dollars price_edited _destroy]
    )
    if attributes[:perfectbook_trip_id].to_s.start_with?("shopify:")
      attributes[:shopify_product_id] = attributes[:perfectbook_trip_id].delete_prefix("shopify:")
      attributes[:perfectbook_trip_id] = nil
      attributes[:perfectbook_departure_id] = nil
    elsif attributes.key?(:perfectbook_trip_id) && (attributes[:perfectbook_trip_id].present? || !attributes.key?(:shopify_product_id))
      attributes[:shopify_product_id] = nil
    end
    attributes
  end
end
