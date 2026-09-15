class AttachmentsController < ApplicationController
  before_action :set_attachment

  def show
    send_data @attachment.blob.download, filename: @attachment.filename.to_s,
      type: @attachment.content_type, disposition: "attachment"
  end

  def move_to_perfectbook
    message = @attachment.record
    conversation = message.conversation
    blob = @attachment.blob
    blob.update!(metadata: blob.metadata.merge("sensitive" => true))
    begin
      blob.delete
    rescue StandardError
      return redirect_to inbox_thread_path(conversation), alert: "Storage deletion failed. The document is still in triage; please retry."
    end
    @attachment.transaction do
      ActiveStorage::Attachment.where(blob_id: blob.id).delete_all
      blob.destroy!
      Note.create!(notable: conversation,
        body: "Collect the sensitive document from message #{message.id} in PerfectBook. The file was removed from CRM storage.")
      ActivityEvent.create!(subject: conversation.linkable || conversation, kind: "email",
        summary: "Sensitive document removed from CRM; collect in PerfectBook",
        occurred_at: Time.current, metadata: { "conversation_id" => conversation.id, "message_id" => message.id })
    end
    redirect_to inbox_thread_path(conversation), notice: "Removed from CRM. Collect the document in PerfectBook."
  end

  private

  def set_attachment
    @attachment = ActiveStorage::Attachment.where(record_type: "Message", name: "files").find(params[:id])
  end
end
