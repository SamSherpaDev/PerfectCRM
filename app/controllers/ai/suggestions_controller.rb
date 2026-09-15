module Ai
  # One follow-up task proposal. Accept creates a real Task; nothing is
  # created automatically.
  class SuggestionsController < ApplicationController
    include Guard

    def create
      find_conversation
      if (blocked = ai_blocked_reason)
        @fallback = blocked
        return respond_to do |format|
                 format.turbo_stream
                 format.html { redirect_to inbox_thread_path(@conversation) }
               end
      end

      @result = Ai::Suggest.call(@conversation)
      @conversation.reload
      @fallback = :error if @conversation.ai_suggestion_title.blank?
      respond_to do |format|
        format.turbo_stream
        format.html { redirect_to inbox_thread_path(@conversation) }
      end
    end

    def accept
      find_conversation
      task = Ai::Suggest.accept!(@conversation)
      if task
        redirect_to inbox_thread_path(@conversation), notice: "Follow-up added for #{task.due_on.strftime('%b %-d')}.", status: :see_other
      else
        redirect_to inbox_thread_path(@conversation), alert: "There is no suggestion to accept.", status: :see_other
      end
    end
  end
end
