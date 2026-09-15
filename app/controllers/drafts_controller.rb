# Persists the reply box without sending. "Save draft" posts the same
# fields as Send (via the submit button's formaction) so the two never
# drift; drafts are also the only place AI text will appear later.
class DraftsController < ApplicationController
  def update
    owner = find_owner
    return render_not_found unless owner

    conversation = params[:conversation_id].present? ?
      owner.conversations.find_by(id: params[:conversation_id]) : nil
    @draft = Draft.for_owner(owner, conversation: conversation)
    @draft.assign_attributes(draft_attributes)
    @draft.attach_uploads(params.dig(:message, :files))

    if @draft.empty?
      @draft.destroy if @draft.persisted?
      @saved = false
    else
      @draft.save!
      @saved = true
    end

    respond_to do |format|
      format.turbo_stream
      format.html { redirect_to owner, notice: @saved ? "Draft saved." : "Draft cleared." }
    end
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

  def draft_attributes
    permitted = params.fetch(:message, {}).permit(:to, :cc, :bcc, :subject, :body, :template_id, :perfectbook_booking_id)
    {
      to_addrs: permitted[:to].to_s, cc_addrs: permitted[:cc].to_s, bcc_addrs: permitted[:bcc].to_s,
      subject: permitted[:subject].to_s, body: permitted[:body].to_s,
      template_id: permitted[:template_id].presence,
      perfectbook_booking_id: permitted[:perfectbook_booking_id].presence
    }
  end

  def render_not_found
    render file: Rails.public_path.join("404.html"), status: :not_found, layout: false
  end
end
