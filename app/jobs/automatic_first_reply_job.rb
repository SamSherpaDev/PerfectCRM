class AutomaticFirstReplyJob < ApplicationJob
  queue_as :default
  discard_on ActiveRecord::RecordNotFound

  def perform(lead_id)
    lead = Lead.find(lead_id)
    email = lead.email.to_s.strip.downcase
    message = nil
    # SQLite serializes writers; the unique address reservation and message
    # commit together. Retries can only re-enqueue that one persisted message.
    AutomaticFirstReply.transaction do
      existing = AutomaticFirstReply.find_by(email: email)
      if existing
        message = existing.message if existing.lead_id == lead.id
        AutomaticFirstReply.log(lead, "skipped (already reserved)") unless message
        next
      end
      reason = AutomaticFirstReply.skip_reason(lead, email: email)
      if reason
        AutomaticFirstReply.log(lead, "skipped (#{reason})")
        next
      end
      if Time.current < lead.created_at + 2.minutes
        self.class.set(wait_until: lead.created_at + 2.minutes).perform_later(lead.id)
        next
      end
      template = Template.active.for_purpose(:first_reply).ordered.first
      unless template
        AutomaticFirstReply.log(lead, "skipped (First reply template unavailable)")
        next
      end
      context = TemplateContext.for_reply(to: email, owner: lead)[:context]
      rendered = template.rendered(context)
      if rendered.values.any? { |text| text.match?(/\[missing:/i) }
        AutomaticFirstReply.log(lead, "skipped (missing placeholder)")
        next
      end
      reservation = AutomaticFirstReply.create!(email: email, lead: lead)
      message = Outbound::Composer.call(owner: lead, conversation: Conversation.latest_for(lead),
        params: rendered.merge(to: email, template_id: template.id, automatic_first_reply: true))
      # Recipient corrections cannot silently turn a screened address into a
      # different automatic recipient.
      raise ActiveRecord::RecordInvalid, message unless message.to_list == [ email ]
      reservation.update!(message: message)
      AutomaticFirstReply.log(lead, "queued", message: message)
    end
    OutboundDeliveryJob.perform_later(message.id) if message&.status == "queued"
  rescue ActiveRecord::RecordInvalid, Outbound::Uploads::SensitiveDocument => error
    AutomaticFirstReply.log(lead, "skipped (sending gate: #{error.message.truncate(200)})")
  end
end
