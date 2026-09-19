# Sends a group departure merge: one personal email per recipient, each
# rendered from live data. Logging rules: see README.md, "Replying". Sending
# only runs from a complete batch (no malformed lines); the show page is
# the per-batch summary.
class GroupSendsController < ApplicationController
  def create
    @template = Template.find_by(id: params[:template_id])
    return redirect_to merge_templates_path, alert: "Pick a template first." unless @template

    lines = params[:recipients].to_s
    batch = MergeBatch.build(template: @template, recipient_lines: lines,
      context_for: ->(recipient) { TemplateContext.for_recipient(recipient, departure_id: params[:departure_id]) })

    unless batch.complete?
      return redirect_to merge_templates_path(template_id: @template.id, recipients: lines,
        departure_id: params[:departure_id]),
        alert: "Fix #{batch.errors.size} #{'line'.pluralize(batch.errors.size)} before sending."
    end

    group = nil
    messages = GroupSend.transaction do
      group = GroupSend.create!(template: @template,
        perfectbook_departure_id: params[:departure_id].presence,
        total_count: batch.size, recipient_lines: lines)
      prepared = batch.messages.map do |preview|
        owner = match_owner(preview.email)
        confirmation = params.dig(:recipient_confirmations, owner.to_gid_param) if owner
        Outbound::Composer.new(owner,
          { to: preview.email, subject: preview.subject, body: preview.body,
            template_id: @template.id, recipient_confirmation: confirmation }, nil, group).build
      end
      prepared.each do |message|
        message.save!
        @template.record_use!
      end
      prepared
    end
    messages.each { |message| OutboundDeliveryJob.perform_later(message.id) }
    redirect_to group_send_path(group), notice: "Sending #{batch.size} personal emails…"
  rescue Outbound::OwnerLookup::Conflict => e
    redirect_to merge_templates_path(template_id: @template&.id, recipients: lines, departure_id: params[:departure_id]),
      alert: "Could not send: #{e.message}"
  rescue ActiveRecord::RecordInvalid => e
    redirect_to merge_templates_path(template_id: @template&.id, recipients: lines, departure_id: params[:departure_id]),
      alert: "Could not send: #{e.record.errors.full_messages.to_sentence}"
  end

  def show
    @group_send = GroupSend.includes(messages: [ :template, { conversation: :owner } ]).find(params[:id])
    @group_send.refresh_status!
  end

  private

  def match_owner(email)
    Outbound::OwnerLookup.for_email(email)
  end
end
