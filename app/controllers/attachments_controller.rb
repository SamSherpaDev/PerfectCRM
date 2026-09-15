class AttachmentsController < ApplicationController
  before_action :set_attachment, only: %i[show move_to_perfectbook]

  def show
    authorize_blob!
    redirect_to rails_blob_path(@attachment.blob, disposition: "attachment")
  end

  # Hands a sensitive file to PerfectBook, then deletes it from the CRM and
  # records an activity event. Behind PerfectBook::DocumentUploader so the
  # CRM side ships before the PerfectBook upload endpoint exists.
  def move_to_perfectbook
    message = @attachment.record
    conversation = message.conversation
    linkable = conversation.linkable
    booking_id = params[:booking_id].to_s.presence
    contact_id = perfectbook_contact_id_for(linkable)

    begin
      PerfectBook::DocumentUploader.upload(attachment: @attachment, booking_id: booking_id, contact_id: contact_id)
    rescue NotImplementedError => e
      return redirect_to inbox_thread_path(conversation), alert: e.message
    end

    filename = @attachment.filename.to_s
    @attachment.purge
    if linkable
      ActivityEvent.create!(subject: linkable, kind: "email",
        summary: "Moved #{filename} to PerfectBook",
        occurred_at: Time.current,
        metadata: { "conversation_id" => conversation.id, "booking_id" => booking_id, "filename" => filename })
    end
    redirect_to inbox_thread_path(conversation), notice: "Moved #{filename} to PerfectBook."
  end

  private

  def set_attachment
    @attachment = ActiveStorage::Attachment.find(params[:id])
    unless @attachment.record_type == "Message"
      redirect_to inbox_path, alert: "Attachment not found."
    end
  end

  def authorize_blob!
    # Signed in via ApplicationController; attachments never use the public
    # Active Storage routes (see config.active_storage.draw_routes = false).
    true
  end

  def perfectbook_contact_id_for(linkable)
    linkable.try(:perfectbook_contact_id)
  end
end
