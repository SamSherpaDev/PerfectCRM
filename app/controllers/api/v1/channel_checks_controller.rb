module Api
  module V1
    # Server-to-server only: independent of storefront credentials and sessions.
    class ChannelChecksController < ActionController::API
      before_action :authenticate_channel_checks!

      private

      def authenticate_channel_checks!
        expected = ENV["CHANNEL_CHECKS_TOKEN"].to_s
        supplied = request.headers["Authorization"].to_s.delete_prefix("Bearer ")
        unless expected.present? && request.headers["Authorization"].to_s.start_with?("Bearer ") &&
            ActiveSupport::SecurityUtils.secure_compare(expected, supplied)
          render_error("unauthorized", :unauthorized)
        end
      end

      def render_error(error, status)
        render json: { error: error }, status: status
      end
    end
  end
end
