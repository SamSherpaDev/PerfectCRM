class InboxController < ApplicationController
  include ReplyBox
  TABS = %w[waiting waiting_them all triage].freeze

  def index
    @tab = TABS.include?(params[:tab].to_s) ? params[:tab].to_s : "waiting"
    base = Conversation.where(ignored: false).ordered.includes(:linkable)
    waiting = base.merge(Conversation.waiting_on_you).linked
    @waiting_count = waiting.count
    @waiting_them_count = base.where.not(id: Conversation.waiting_on_you.select(:id))
      .where.not(linkable_type: nil).count
    @all_count = base.count
    @triage_count = Conversation.needs_triage.count

    @conversations = case @tab
    when "waiting"
      waiting
    when "waiting_them"
      base.where.not(id: Conversation.waiting_on_you.select(:id)).where.not(linkable_type: nil)
    when "triage"
      Conversation.needs_triage.ordered.includes(:linkable)
    else
      base
    end
    @page = [ params[:page].to_i, 1 ].max
    @has_older = @conversations.offset(@page * 50).exists?
    @conversations = @conversations.offset((@page - 1) * 50).limit(50).to_a
    page_threads = Conversation.where(id: @conversations.map(&:id))
    latest_ids = page_threads.select(Arel.sql("(SELECT messages.id FROM messages WHERE messages.conversation_id = conversations.id ORDER BY COALESCE(messages.sent_at, messages.created_at) DESC, messages.id DESC LIMIT 1)"))
    @latest_messages = Message.where(id: latest_ids).index_by(&:conversation_id)
    @document_thread_ids = page_threads.merge(Conversation.sensitive_documents.or(Conversation.held_documents)).pluck(:id).to_set
  end

  def show
    @conversation = Conversation.includes(messages: { files_attachments: :blob }).find(params[:id])
    @conversation.mark_read!
    @messages = @conversation.messages.newest_first.includes(files_attachments: :blob)
    @linkable = @conversation.linkable
    @reply_owner = @conversation.owner
    return unless @reply_owner

    @reply_conversation = @conversation
    @reply_draft = @conversation.draft || @conversation.build_draft(owner: @reply_owner)
    load_reply_context
  end
end
