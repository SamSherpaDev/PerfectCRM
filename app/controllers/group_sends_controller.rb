# Sends a group departure merge: one personal email per recipient, each
# rendered from live data and each logged on its own timeline. Sending
# only runs from a complete batch (no malformed lines); the show page is
# the per-batch summary.
class GroupSendsController < ApplicationController
  def create
    @template = Template.find_by(id: params[:template_id])
    return redirect_to merge_templates_path, alert: "Pick a template first." unless @template

    lines = params[:recipients].to_s
    contexts = live_contexts(lines)
    batch = MergeBatch.build(template: @template, recipient_lines: lines,
      context_for: ->(recipient) { contexts[recipient.email.strip.downcase] || {} })

    unless batch.complete?
      return redirect_to merge_templates_path(template_id: @template.id, recipients: lines,
        departure_id: params[:departure_id]),
        alert: "Fix #{batch.errors.size} #{'line'.pluralize(batch.errors.size)} before sending."
    end

    group = GroupSend.create!(template: @template,
      perfectbook_departure_id: params[:departure_id].presence,
      total_count: batch.size, recipient_lines: lines)
    batch.messages.each do |preview|
      owner = match_owner(preview.email)
      message = Outbound::Composer.call(owner: owner,
        params: { to: preview.email, subject: preview.subject, body: preview.body,
                  template_id: @template.id },
        group_send: group)
      OutboundDeliveryJob.perform_later(message.id)
    end
    redirect_to group_send_path(group), notice: "Sending #{batch.size} personal emails…"
  rescue ActiveRecord::RecordInvalid => e
    redirect_to merge_templates_path(template_id: @template&.id, recipients: lines),
      alert: "Could not send: #{e.record.errors.full_messages.to_sentence}"
  end

  def show
    @group_send = GroupSend.includes(messages: [ :template, { conversation: :owner } ]).find(params[:id])
    @group_send.refresh_status!
  end

  private

  # Per-recipient live contexts for departure bookings: matched CRM
  # records fill every placeholder they can; strangers get names only.
  def live_contexts(lines)
    MergeBatch.parse_recipients(lines).index_with do |recipient|
      TemplateContext.for_recipient(recipient, departure_id: params[:departure_id])
    end.transform_keys { |recipient| recipient.email.strip.downcase }
  end

  def match_owner(email)
    Outbound::OwnerLookup.for_email(email)
  end
end
