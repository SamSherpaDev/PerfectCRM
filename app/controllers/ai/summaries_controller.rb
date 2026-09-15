module Ai
  # Three-bullet thread summary, cached per conversation.
  class SummariesController < ApplicationController
    include Guard

    def create
      find_conversation
      if @conversation.ai_summary.present?
        @summary = @conversation.ai_summary
        @cached = true
        return respond_to do |format|
                 format.turbo_stream
                 format.html { redirect_to inbox_thread_path(@conversation) }
               end
      end
      if (blocked = ai_blocked_reason)
        @fallback = blocked
        return respond_to do |format|
                 format.turbo_stream
                 format.html { redirect_to inbox_thread_path(@conversation) }
               end
      end

      @result = Ai::Summarize.call(@conversation)
      @summary = @result.status == :ok ? @conversation.reload.ai_summary : nil
      @fallback = :error if @summary.blank?
      respond_to do |format|
        format.turbo_stream
        format.html { redirect_to inbox_thread_path(@conversation) }
      end
    end
  end
end
