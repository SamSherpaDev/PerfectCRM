module Ai
  # Approval-only reply draft for the thread. Fills the dashed-edge .draft
  # block the captain edits before Send; nothing here ever sends.
  class DraftsController < ApplicationController
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

      @result = Ai::Draft.call(@conversation)
      @draft_text = @result.text
      @fallback = :error if @draft_text.blank?
      respond_to do |format|
        format.turbo_stream
        format.html { redirect_to inbox_thread_path(@conversation) }
      end
    end
  end
end
