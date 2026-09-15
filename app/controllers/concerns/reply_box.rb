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
    @reply_bookings = TemplateContext.bookings_for(owner)
    @reply_context = TemplateContext.for(owner)
    @reply_booking_contexts = @reply_bookings.to_h do |booking|
      [ booking.perfectbook_id, TemplateContext.for(owner, booking: booking) ]
    end
    @reply_chips = Template.active.order(usage_count: :desc, last_used_at: :desc).limit(3)
    @outbound_messages = Message.for_owner(owner).newest_first.limit(50).to_a
  end

  # Activity events and outbound messages, newest first, for one scroll.
  def timeline_items(events, messages)
    event_rows = events.map { |event| [ event.occurred_at, :event, event ] }
    message_rows = messages.map do |message|
      [ message.sent_at || message.created_at, :message, message ]
    end
    (event_rows + message_rows).sort_by { |time, _, _| time || Time.zone.at(0) }.reverse
  end
end
