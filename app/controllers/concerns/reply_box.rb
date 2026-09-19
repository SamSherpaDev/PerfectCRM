# Shared reply-box setup for the client, lead, organization, and inbox
# thread views: the conversation a reply continues, its persisted draft,
# the PerfectBook bookings that fill {{placeholders}}, and the outbound
# messages shown on the timeline with their delivery state.
module ReplyBox
  extend ActiveSupport::Concern

  private

  def load_reply_box(owner)
    @reply_owner = owner
    if params[:new_thread].present?
      @reply_conversation = nil
      @reply_draft = Draft.for_owner(owner, conversation: nil)
    else
      @reply_conversation = Conversation.latest_for(owner)
      @reply_draft = Draft.for_owner(owner, conversation: @reply_conversation)
    end
    prefill_document_nudge(owner)
    prefill_task_nudge(owner)
    # A failed send redirects back with its words kept in the draft: open
    # the envelope so the flagged fields are visible instead of folded.
    send_alerts = [ "Could not send", Outbound::Uploads::REFUSAL ]
    @envelope_open = send_alerts.any? { |prefix| flash[:alert].to_s.start_with?(prefix) }
    load_reply_context
    @outbound_messages = Message.for_owner(owner).for_timeline.newest_first.limit(@events_page.to_i * 100 + 1).to_a
  end

  # Today's Nudge link (?template=&task=) and the pipeline's ?nudge=1 land in
  # the lead and client composer with the template already rendered. An
  # untouched draft only; the captain's own text is never overwritten. The
  # organization page still shows the Suggested message card instead.
  def prefill_task_nudge(owner)
    return unless owner.is_a?(Lead) || owner.is_a?(Client)
    return if params[:template].blank? || !@reply_draft.empty?

    template = Template.active.find_by(id: params[:template])
    return if template.nil?

    unless params[:nudge] == "1" || owner.tasks.exists?(id: params[:task], template_id: template.id)
      return
    end

    context = TemplateContext.for(owner)
    context["trip"] ||= owner.trip_interest if owner.is_a?(Lead) && owner.trip_interest.present?
    @reply_draft.assign_attributes(
      subject: TemplateRenderer.render(template.subject, context),
      body: TemplateRenderer.render(template.body, context),
      template: template
    )
    @composer_open = true
  end

  # Booking-card nudge (?nudge_booking_id=): prefill an untouched draft
  # with the document-request template naming exactly the missing types.
  # Never clobbers the captain's own draft text.
  def prefill_document_nudge(owner)
    mirror_id = params[:nudge_booking_id].presence
    return if mirror_id.nil? || !@reply_draft.empty?

    booking = PerfectBook::Booking.find_by(id: mirror_id,
      perfectbook_contact_id: owner.try(:perfectbook_contact_id))
    return if booking.nil? || booking.missing_lines.blank?

    nudge = TemplateContext.for_document_nudge(owner, booking)

    @reply_draft.assign_attributes(subject: nudge[:subject], body: nudge[:body],
      template: nudge[:template], perfectbook_booking_id: booking.perfectbook_id)
  end

  def load_reply_context
    @reply_to = if @reply_draft.persisted?
      @reply_draft.to_addrs
    elsif @reply_conversation
      @reply_conversation.thread_parent&.recipients&.join(", ")
    else
      @reply_owner.try(:display_email) || @reply_owner.try(:email)
    end
    @reply_data = TemplateContext.for_reply(to: @reply_to, owner: @reply_owner,
      booking_id: @reply_draft.perfectbook_booking_id)
    @reply_context = @reply_data[:context]
    @reply_chips = Template.active.order(usage_count: :desc, last_used_at: :desc).limit(3)
  end

  # Activity events and outbound messages, newest first, for one scroll.
  def timeline_items(events, messages)
    event_rows = events.map { |event| [ event.occurred_at, :event, event ] }
    message_rows = messages.map do |message|
      [ message.sent_at || message.created_at, :message, message ]
    end
    rows = (event_rows + message_rows).sort_by { |time, kind, record| [ time || Time.zone.at(0), kind.to_s, record.id ] }.reverse
    @older_events = rows.size > @events_page * 100
    rows.slice((@events_page - 1) * 100, 100) || []
  end
end
