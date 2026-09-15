module Ai
  # Shared guard: kill switch, per-record opt-out, and plain fallbacks.
  module Guard
    extend ActiveSupport::Concern

    private

    def find_conversation
      @conversation = Conversation.find(params[:conversation_id] || params[:id])
    end

    # Returns a fallback symbol when AI may not run, nil when it may.
    def ai_blocked_reason
      settings = Setting.current
      return :off unless settings.ai_enabled?
      return :off if settings.ai_api_key.blank? || settings.ai_model.blank?
      return :opt_out unless @conversation.ai_enabled_for_linkable?
      return :over_cap if Ai::Client.over_daily_cap?(settings)

      nil
    end
  end
end
