module DraftParameters
  extend ActiveSupport::Concern

  private

  def draft_attributes
    permitted = params.fetch(:message, {}).permit(:to, :cc, :bcc, :subject, :body, :template_id, :perfectbook_booking_id)
    {
      to_addrs: permitted[:to].to_s, cc_addrs: permitted[:cc].to_s, bcc_addrs: permitted[:bcc].to_s,
      subject: permitted[:subject].to_s, body: permitted[:body].to_s,
      template_id: permitted[:template_id].presence,
      perfectbook_booking_id: permitted[:perfectbook_booking_id].presence
    }
  end

  def redirect_draft_recipients(owner, draft)
    return unless owner.respond_to?(:resolve_redirected_field)

    draft.to_addrs = owner.resolve_redirected_field(draft.to_addrs)
    draft.cc_addrs = owner.resolve_redirected_field(draft.cc_addrs)
    draft.bcc_addrs = owner.resolve_redirected_field(draft.bcc_addrs)
  end
end
