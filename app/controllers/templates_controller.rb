class TemplatesController < ApplicationController
  before_action :set_template, only: %i[edit update destroy duplicate archive unarchive move use]

  def document_nudge
    @booking = PerfectBook::Booking.find(params[:booking_id])
    @recipient = Client.find_by(perfectbook_contact_id: @booking.perfectbook_contact_id) ||
      Lead.open.find_by(perfectbook_contact_id: @booking.perfectbook_contact_id) ||
      Lead.lost.find_by(perfectbook_contact_id: @booking.perfectbook_contact_id)
    raise ActiveRecord::RecordNotFound unless @recipient

    nudge = TemplateContext.for_document_nudge(@recipient, @booking)
    @nudge_template = nudge[:template]
    @subject = nudge[:subject]
    @body = nudge[:body]
    @reply_path = polymorphic_path(@recipient, nudge_booking_id: @booking.id, anchor: "reply-heading")
  end

  def index
    @tab = params[:tab] == "archived" ? "archived" : "active"
    @active_count = Template.active.count
    @archived_count = Template.archived.count
    scope = (@tab == "archived" ? Template.archived : Template.active).ordered
    @grouped = Template.purposes.keys.filter_map do |purpose|
      records = scope.for_purpose(purpose).to_a
      [ purpose, records ] if records.any?
    end
  end

  def new
    @template = Template.new(purpose: params[:purpose].presence_in(Template.purposes.keys) || "custom")
  end

  def create
    @template = Template.new(template_params)
    if @template.save
      redirect_to templates_path, notice: "Template saved."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
  end

  def update
    if @template.update(template_params)
      redirect_to templates_path, notice: "Template saved."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    if @template.referenced?
      @template.archive!
      redirect_to templates_path, notice: "Template archived because it is referenced by correspondence."
    else
      @template.destroy!
      redirect_to templates_path, notice: "Template deleted."
    end
  end

  # Live preview for the unsaved form: subject/body come from the form fields.
  def collection_preview
    @template = Template.new(subject: params.dig(:template, :subject), body: params.dig(:template, :body))
    render partial: "preview_contents", locals: { template: @template }
  end

  def duplicate
    copy = @template.dup
    copy.name = "#{@template.name} (copy)"
    copy.usage_count = 0
    copy.last_used_at = nil
    copy.archived_at = nil
    # The dup carries the original position; take the next free one so
    # move up/down keeps working after duplicating.
    copy.position = (Template.maximum(:position) || 0) + 1
    copy.save!
    redirect_to edit_template_path(copy), notice: "Template duplicated."
  end

  def archive
    @template.archive!
    redirect_to templates_path, notice: "Template archived."
  end

  def unarchive
    @template.unarchive!
    redirect_to templates_path(tab: "archived"), notice: "Template restored."
  end

  def move
    @template.move(params[:direction] == "down" ? "down" : "up")
    redirect_to templates_path
  end

  def reply_context
    owner_class = { "Client" => Client, "Lead" => Lead, "Organization" => Organization }[params[:owner_type]]
    owner = owner_class&.find(params[:owner_id])
    return head :not_found unless owner

    render json: TemplateContext.for_reply(to: params[:to], owner: owner, booking_id: params[:booking_id])
  end

  def use
    render json: { id: @template.id, name: @template.name, **@template.rendered(use_context) }
  end

  # Picker integration and usage semantics: see README.md, "Templates".
  def picker
    @query = params[:q].to_s.strip
    scope = Template.active.ordered
    scope = scope.where("name LIKE :q OR subject LIKE :q OR body LIKE :q", q: "%#{@query}%") if @query.present?
    @templates = scope.limit(30)
    respond_to do |format|
      format.html { render layout: false if turbo_frame_request? }
      format.json do
        render json: @templates.map { |template| { id: template.id, name: template.name, purpose: template.purpose_label, **template.rendered(picker_context) } }
      end
    end
  end

  # Group-departure merge: pick a template, take recipients from a
  # departure's mirrored bookings (or paste), preview each rendered
  # message. Nothing is sent; GroupSendsController consumes MergeBatch.
  def merge
    @templates = Template.active.ordered
    @selected = @templates.find_by(id: params[:template_id]) || @templates.first
    @departures = merge_departures
    @departure = @departures.find { |departure| departure.perfectbook_id.to_s == params[:departure_id].to_s } if params[:departure_id].present?
    @recipient_lines = params[:recipients].presence || recipients_from_departure(@departure)
    @skipped_without_email = @skipped_without_email || 0
  end

  def merge_preview
    @templates = Template.active.ordered
    @selected = @templates.find_by(id: params[:template_id])
    @departures = merge_departures
    @departure = @departures.find { |departure| departure.perfectbook_id.to_s == params[:departure_id].to_s } if params[:departure_id].present?
    @recipient_lines = params[:refill].present? ? recipients_from_departure(@departure).to_s : params[:recipients].to_s
    if @selected.nil?
      flash.now[:alert] = "Pick a template first."
      render :merge, status: :unprocessable_entity
    else
      @batch = MergeBatch.build(template: @selected, recipient_lines: @recipient_lines,
        context_for: ->(recipient) { TemplateContext.for_recipient(recipient, departure_id: params[:departure_id]) })
      @recipient_confirmation_owners = @batch.recipients.filter_map do |recipient|
        owner = Outbound::OwnerLookup.for_email(recipient.email)
        next unless owner.respond_to?(:ambiguous_recipient_emails)

        addresses = [ recipient.email.downcase ] + owner.resolve_redirected_list(recipient.email)
        owner if (addresses & owner.ambiguous_recipient_emails).any?
      end.uniq
      if @batch.errors.any?
        flash.now[:alert] = "#{@batch.errors.size} #{'line'.pluralize(@batch.errors.size)} need#{@batch.errors.size == 1 ? 's' : ''} fixing before this batch can send."
      elsif @batch.recipients.empty?
        flash.now[:alert] = "Add at least one recipient email."
      end
      render :merge
    end
  rescue Outbound::OwnerLookup::Conflict => e
    @batch = nil
    flash.now[:alert] = e.message
    render :merge, status: :unprocessable_entity
  end

  private

  # Departures with mirrored bookings, newest first — the only ones a
  # group send can address. Past departures stay listed: post-trip
  # review asks go to travelers who already returned.
  def merge_departures
    # Note: NULL check only — comparing the integer column to "" makes
    # SQLite drop every row, so a blank string is never queried.
    booked = PerfectBook::Booking.where.not(departure_id: nil).distinct.pluck(:departure_id)
    PerfectBook::Departure.where(perfectbook_id: booked)
      .order(Arel.sql("start_date IS NULL, start_date DESC")).limit(100).to_a
  end

  # "Name <email>" lines from a departure's mirrored bookings. Bookings
  # without a reachable email are counted, never guessed.
  def recipients_from_departure(departure)
    @skipped_without_email = 0
    return nil if departure.nil?

    PerfectBook::Booking.where(departure_id: departure.perfectbook_id)
      .order(:id).filter_map do |booking|
        contact = PerfectBook::Contact.find_by(perfectbook_id: booking.perfectbook_contact_id)
        email = contact&.email.to_s.strip
        if email.blank?
          @skipped_without_email += 1
          next
        end
        contact.name.present? ? "#{contact.name} <#{email}>" : email
      end.join("\n")
  end

  def set_template
    @template = Template.find(params[:id])
  end

  def template_params
    params.require(:template).permit(:name, :purpose, :subject, :body)
  end

  # Extra context keys the caller may pass (flat ?context[first_name]=…).
  def picker_context
    params.fetch(:context, {}).permit(*TemplateRenderer::PLACEHOLDERS).to_h
  end

  def use_context
    params.fetch(:context, {}).permit(*TemplateRenderer::PLACEHOLDERS).to_h
  end
end
