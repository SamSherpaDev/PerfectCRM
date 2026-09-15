# Sends a sensitive file to PerfectBook's traveler-document endpoint.
#
# Sources: a 24-hour DocumentHolding (placeholder on an inbound message)
# or a still-stored ordinary attachment the captain flags. The bytes are
# uploaded through PerfectBook::Client with a stable upload_id per source
# (idempotent replays), then every CRM copy is deleted, an activity event
# records the PerfectBook response, and that booking's mirror refreshes.
class DocumentHandoffsController < ApplicationController
  DOCUMENT_TYPES = %w[passport visa insurance waiver].freeze

  before_action :load_source
  before_action :load_bookings

  def new
  end

  def create
    booking = PerfectBook::Booking.find_by(id: handoff_params[:booking_id])
    traveler = traveler_for(booking, handoff_params[:traveler_id])
    document_type = handoff_params[:document_type].to_s
    unless booking && traveler && DOCUMENT_TYPES.include?(document_type)
      flash.now[:alert] = "Pick the booking, traveler, and document type."
      return render :new, status: :unprocessable_entity
    end
    if @byte_size > DocumentHolding::MAX_BYTES
      flash.now[:alert] = "This file exceeds PerfectBook's 10 MB upload limit."
      return render :new, status: :unprocessable_entity
    end

    result = client.upload_traveler_document(booking_ref: booking.ref,
      traveler_id: traveler["id"], file: download_source, filename: @filename,
      content_type: @content_type, document_type: document_type, upload_id: upload_id)
    remove_source!
    record_handoff!(booking, traveler, document_type, result)
    PerfectBook::SyncBookingsJob.perform_later(perfectbook_contact_id: booking.perfectbook_contact_id)
    redirect_to inbox_thread_path(@message.conversation),
      notice: "Sent #{@filename} to PerfectBook (#{document_type} for #{traveler['first_name']})."
  rescue PerfectBook::UnprocessableError, PerfectBook::BadRequestError => e
    flash.now[:alert] = "PerfectBook refused the file: #{e.message}"
    render :new, status: :unprocessable_entity
  rescue PerfectBook::NotFoundError
    flash.now[:alert] = "PerfectBook could not find that booking or traveler. Refresh bookings and retry."
    render :new, status: :unprocessable_entity
  rescue PerfectBook::Error => e
    flash.now[:alert] = "PerfectBook is unreachable (#{e.message}). Nothing was deleted; retry shortly."
    render :new, status: :service_unavailable
  end

  private

  def client
    PerfectBook::Client.new
  end

  # Exactly one source: holding_id (placeholder bytes) or attachment_id
  # (a stored file the captain flags). Holdings stay live-only: expired
  # or handed-off rows fall back to the expired notice.
  def load_source
    @holding = DocumentHolding.find_by(id: params[:holding_id]) if params[:holding_id].present?
    @attachment = ActiveStorage::Attachment.where(record_type: "Message", name: "files")
      .find_by(id: params[:attachment_id]) if params[:attachment_id].present?
    if @holding
      @message = @holding.message
      @filename = @holding.filename
      @content_type = @holding.content_type
      @byte_size = @holding.byte_size
      unless @holding.live?
        redirect_to inbox_thread_path(@message.conversation),
          alert: "That held file already expired from the holding area. Ask the client to resend it."
      end
    elsif @attachment
      @message = @attachment.record
      @filename = @attachment.filename.to_s
      @content_type = @attachment.blob.content_type
      @byte_size = @attachment.blob.byte_size
    else
      redirect_to inbox_path, alert: "That file is no longer waiting for a hand-off."
    end
  end

  def upload_id
    @holding ? "holding-#{@holding.id}" : "attachment-#{@attachment.id}"
  end

  def download_source
    @holding ? @holding.file.download : @attachment.blob.download
  end

  def remove_source!
    if @holding
      holding_id = @holding.id
      @holding.purge!
      @message.remove_holding_entry!(holding_id)
    else
      blob = @attachment.blob
      blob.delete
      @attachment.transaction do
        ActiveStorage::Attachment.where(blob_id: blob.id).delete_all
        blob.destroy!
      end
    end
  end

  def record_handoff!(booking, traveler, document_type, result)
    owner = @message.conversation.linkable
    summary = "Sent #{@filename} to PerfectBook: #{document_type} for #{traveler['first_name']} " \
      "(booking #{booking.ref}, #{result.document_status}" \
      "#{result.duplicate ? ', replayed upload' : ''})"
    ActivityEvent.create!(subject: owner || @message.conversation, kind: "email",
      summary: summary, occurred_at: Time.current,
      metadata: { "conversation_id" => @message.conversation.id, "message_id" => @message.id,
        "booking_ref" => booking.ref, "traveler_id" => traveler["id"],
        "document_type" => document_type, "document_status" => result.document_status,
        "missing_count" => result.missing_count, "duplicate" => result.duplicate })
    Note.create!(notable: @message.conversation,
      body: "Sent #{@filename} to PerfectBook (#{document_type} for #{traveler['first_name']}, booking #{booking.ref}). The CRM copy was deleted.")
  end

  # Bookings the captain can file this thread under: the linked record's
  # mirrors first, else the nearest upcoming mirrors to pick from.
  def load_bookings
    contact_id = @message&.conversation&.linkable.try(:perfectbook_contact_id)
    @bookings = if contact_id.present?
      PerfectBook::Booking.where(perfectbook_contact_id: contact_id).order(:start_date, :id).to_a
    else
      PerfectBook::Booking.order(Arel.sql("start_date IS NULL, start_date DESC")).limit(50).to_a
    end
  end

  def traveler_for(booking, traveler_id)
    return nil if booking.nil? || traveler_id.blank?

    booking.travelers.find { |traveler| traveler["id"].to_s == traveler_id.to_s }
  end

  def handoff_params
    params.fetch(:handoff, {}).permit(:booking_id, :traveler_id, :document_type)
  end
end
