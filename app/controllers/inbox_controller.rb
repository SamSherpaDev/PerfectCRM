class InboxController < ApplicationController
  TABS = %w[waiting waiting_them all triage].freeze

  def index
    @tab = TABS.include?(params[:tab].to_s) ? params[:tab].to_s : "waiting"
    base = Conversation.where(ignored: false).ordered.includes(:linkable, messages: { files_attachments: :blob })
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
      Conversation.needs_triage.ordered.includes(:linkable, messages: { files_attachments: :blob })
    else
      base
    end
    @page = [ params[:page].to_i, 1 ].max
    @has_older = @conversations.offset(@page * 50).exists?
    @conversations = @conversations.offset((@page - 1) * 50).limit(50)
  end

  def show
    @conversation = Conversation.includes(messages: { files_attachments: :blob }).find(params[:id])
    @conversation.mark_read!
    @messages = @conversation.messages.newest_first.includes(files_attachments: :blob)
    @linkable = @conversation.linkable
  end
end
