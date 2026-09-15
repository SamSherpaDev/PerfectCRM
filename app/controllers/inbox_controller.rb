class InboxController < ApplicationController
  TABS = %w[waiting waiting_them all triage].freeze

  def index
    @tab = TABS.include?(params[:tab].to_s) ? params[:tab].to_s : "waiting"
    base = Conversation.where(ignored: false).ordered.includes(:linkable, messages: { files_attachments: :blob })
    @waiting_count = base.merge(Conversation.waiting_on_you).count
    @waiting_them_count = base.where.not(id: Conversation.waiting_on_you.select(:id))
      .where.not(linkable_type: nil).count
    @all_count = base.count
    @triage_count = Conversation.triage.count

    @conversations = case @tab
    when "waiting"
      base.merge(Conversation.waiting_on_you).where.not(linkable_type: nil)
    when "waiting_them"
      base.where.not(id: Conversation.waiting_on_you.select(:id)).where.not(linkable_type: nil)
    when "triage"
      Conversation.triage.ordered.includes(:linkable, messages: { files_attachments: :blob })
    else
      base
    end.limit(50)
  end

  def show
    @conversation = Conversation.includes(messages: { files_attachments: :blob }).find(params[:id])
    @conversation.mark_read!
    @messages = @conversation.messages.newest_first.includes(files_attachments: :blob)
    @linkable = @conversation.linkable
  end
end
