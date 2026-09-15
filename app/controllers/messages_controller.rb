# Sends a reply (or a new message) from the docked reply box. The composer
# builds a queued Message; delivery runs on Solid Queue so the request
# returns instantly. A failure marks the message failed and keeps the
# draft — the captain's words are never lost.
class MessagesController < ApplicationController
  include DraftParameters

  def create
    owner = find_owner
    return render_not_found unless owner
    if owner.is_a?(Lead) && owner.converted?
      return redirect_to owner, alert: "Converted leads stay read-only."
    end

    conversation = params[:conversation_id].present? ?
      owner.conversations.find_by(id: params[:conversation_id]) : nil
    message = Outbound::Composer.call(owner: owner, params: message_params, conversation: conversation)
    OutboundDeliveryJob.perform_later(message.id)
    redirect_to owner, notice: "Sending your reply…"
  rescue ActiveRecord::RecordInvalid => e
    keep_draft(owner, conversation)
    destination = conversation ? inbox_thread_path(conversation) : polymorphic_path(owner, new_thread: 1)
    redirect_to destination, alert: "Could not send: #{e.record.errors.full_messages.to_sentence}"
  end

  # A failed delivery keeps its Message; retry re-queues the same words.
  def retry
    message = Message.find(params[:id])
    owner = message.owner
    return render_not_found unless owner || message.group_send
    destination = message.group_send ? group_send_path(message.group_send) : owner_path_for(owner)

    if Message.where(id: message.id, status: "failed").update_all(status: "queued", send_error: nil, updated_at: Time.current) == 1
      OutboundDeliveryJob.perform_later(message.id)
      redirect_to destination, notice: "Retrying delivery…"
    else
      redirect_to destination, alert: "Only a failed message can be retried."
    end
  end

  # Attachment downloads go through here (never the default Active Storage
  # routes) so only the signed-in captain can fetch them.
  def attachment
    message = Message.find(params[:id])
    return render_not_found unless message.owner

    file = message.files.find(params[:attachment_id])
    send_data file.download, filename: file.filename.to_s,
      type: file.content_type, disposition: "attachment"
  end

  private

  def find_owner
    if params[:client_id]
      Client.find_by(id: params[:client_id])
    elsif params[:lead_id]
      Lead.find_by(id: params[:lead_id])
    elsif params[:organization_id]
      Organization.find_by(id: params[:organization_id])
    end
  end

  def message_params
    params.fetch(:message, {}).permit(:to, :cc, :bcc, :subject, :body, :template_id, files: [])
  end

  # The send failed validation (no recipient, blank subject/body): stash
  # the attempt as the draft so nothing is lost across the redirect.
  def keep_draft(owner, conversation)
    return unless owner
    draft = Draft.for_owner(owner, conversation: conversation)
    draft.assign_attributes(draft_attributes)
    draft.attach_uploads(params.dig(:message, :files))
    if draft.empty?
      draft.destroy if draft.persisted?
    else
      draft.save
    end
  end

  def owner_path_for(owner)
    case owner
    when Client then client_path(owner)
    when Lead then lead_path(owner)
    when Organization then organization_path(owner)
    end
  end

  def render_not_found
    render file: Rails.public_path.join("404.html"), status: :not_found, layout: false
  end
end
