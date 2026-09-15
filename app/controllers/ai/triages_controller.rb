module Ai
  # Inbound triage classification with a one-line reason and a suggested
  # lead source. Confirmations are logged for later prompt tuning.
  class TriagesController < ApplicationController
    include Guard

    def create
      find_conversation
      if (blocked = ai_blocked_reason)
        # Triage cards still show the manual buttons; the AI line falls back.
        @fallback = blocked
        return respond_to do |format|
                 format.turbo_stream
                 format.html { redirect_to inbox_thread_path(@conversation) }
               end
      end

      @result = Ai::Triage.call(@conversation)
      @conversation.reload
      @fallback = :error if @conversation.ai_triage.blank?
      respond_to do |format|
        format.turbo_stream
        format.html { redirect_to inbox_thread_path(@conversation) }
      end
    end

    def confirm
      find_conversation
      category = Ai::Triage.confirm!(@conversation, params[:category])
      redirect_to inbox_thread_path(@conversation), notice: "Triage confirmed as #{category.humanize}.", status: :see_other
    end
  end
end
