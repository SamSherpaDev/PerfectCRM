class TemplatesController < ApplicationController
  before_action :set_template, only: %i[edit update destroy duplicate archive unarchive move use]

  def document_nudge
    @booking = PerfectBook::Booking.find(params[:booking_id])
    @recipient = Client.find_by(perfectbook_contact_id: @booking.perfectbook_contact_id) ||
      Lead.open.find_by(perfectbook_contact_id: @booking.perfectbook_contact_id) ||
      Lead.lost.find_by(perfectbook_contact_id: @booking.perfectbook_contact_id)
    raise ActiveRecord::RecordNotFound unless @recipient

    template = Template.active.for_purpose(:document_request).ordered.first
    context = {
      "full_name" => @recipient.name, "first_name" => @recipient.name.split.first,
      "trip" => @booking.trip_name, "departure_dates" => helpers.date_range(@booking.start_date, @booking.end_date),
      "booking_reference" => @booking.ref, "payment_reference" => @booking.ref,
      "missing_documents" => "[Check missing documents in PerfectBook]",
      "my_name" => "Sam", "signature" => "Sam"
    }
    @subject = TemplateRenderer.render(template&.subject.presence || "Documents for {{trip}}", context)
    body = template&.body.presence || "Hi {{first_name}},\n\nPlease send the documents we discussed through PerfectBook.\n\n{{signature}}"
    @body = TemplateRenderer.render(body, context) + "\n\n#{@recipient.name} · #{@booking.trip_name}\n#{context['departure_dates']}\nBooking: #{@booking.ref}"
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
    @template.destroy!
    redirect_to templates_path, notice: "Template deleted."
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

  # One-tap insert from the picker: counts the use and returns rendered text.
  def use
    @template.record_use!
    render json: { id: @template.id, **@template.rendered(use_context) }
  end

  # Compact embeddable list for the reply box (a later mail task embeds
  # templates/_picker); JSON returns each row rendered and ready to insert.
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

  # Group-departure merge: pick a template, paste recipients, preview each
  # rendered message. Nothing is sent; the mail task consumes MergeBatch.
  def merge
    @templates = Template.active.ordered
    @selected = @templates.find_by(id: params[:template_id]) || @templates.first
  end

  def merge_preview
    @templates = Template.active.ordered
    @selected = @templates.find_by(id: params[:template_id])
    @recipient_lines = params[:recipients].to_s
    if @selected.nil?
      flash.now[:alert] = "Pick a template first."
      render :merge, status: :unprocessable_entity
    else
      @batch = MergeBatch.build(template: @selected, recipient_lines: @recipient_lines)
      flash.now[:alert] = "Add at least one recipient email." if @batch.recipients.empty?
      render :merge
    end
  end

  private

  def set_template
    @template = Template.find(params[:id])
  end

  def template_params
    params.require(:template).permit(:name, :purpose, :subject, :body)
  end

  # Extra context keys the caller may pass (flat ?context[first_name]=…).
  # Everything else falls back to the sample context inside #rendered.
  def picker_context
    params.fetch(:context, {}).permit(*TemplateRenderer::PLACEHOLDERS).to_h
  end

  def use_context
    params.fetch(:context, {}).permit(*TemplateRenderer::PLACEHOLDERS).to_h
  end
end
