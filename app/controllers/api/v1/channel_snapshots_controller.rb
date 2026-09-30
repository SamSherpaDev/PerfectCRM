module Api
  module V1
    # Server-to-server only: independent of storefront credentials and sessions.
    class ChannelSnapshotsController < ActionController::API
      MAX_BODY_BYTES = 4 * 1024
      FIELDS = %w[channel checked_at open_items review_count review_rating follower_count inquiries].freeze
      before_action :authenticate_channel_checks!

      def create
        return render_error("json_required", :unsupported_media_type) unless request.media_type == "application/json"

        raw = request.body.read(MAX_BODY_BYTES + 1)
        return render_error("too_large", :content_too_large) if raw.bytesize > MAX_BODY_BYTES

        body = JSON.parse(raw)
        unless body.is_a?(Hash) && body.keys == [ "snapshot" ] && valid_shape?(body["snapshot"])
          return render_error("invalid_snapshot", :unprocessable_entity)
        end

        attributes = body.fetch("snapshot")
        checked_at = Time.iso8601(attributes.fetch("checked_at"))
        snapshot = ChannelSnapshot.new(attributes.merge("checked_at" => checked_at))
        if snapshot.save
          render json: { id: snapshot.id, channel: snapshot.channel, checked_at: snapshot.checked_at.iso8601 }, status: :created
        else
          render json: { error: "invalid_snapshot", fields: snapshot.errors.attribute_names }, status: :unprocessable_entity
        end
      rescue JSON::ParserError
        render_error("invalid_json", :bad_request)
      rescue ArgumentError
        render_error("invalid_snapshot", :unprocessable_entity)
      end

      private

      def authenticate_channel_checks!
        expected = ENV["CHANNEL_CHECKS_TOKEN"].to_s
        supplied = request.headers["Authorization"].to_s.delete_prefix("Bearer ")
        unless expected.present? && request.headers["Authorization"].to_s.start_with?("Bearer ") &&
            ActiveSupport::SecurityUtils.secure_compare(expected, supplied)
          render_error("unauthorized", :unauthorized)
        end
      end

      def valid_shape?(data)
        return false unless data.is_a?(Hash) && (data.keys - FIELDS).empty?
        return false unless %w[channel checked_at open_items].all? { |key| data.key?(key) }
        return false unless data["channel"].is_a?(String) && data["checked_at"].is_a?(String)
        # An explicit offset avoids treating an agent's local clock as Pacific.
        return false unless data["checked_at"].match?(/(?:Z|[+-]\d{2}:\d{2})\z/)
        return false if AdSpend::SOURCES.include?(data["channel"]) && data.key?("inquiries")
        return false unless %w[review_count follower_count inquiries].all? { |key|
          data[key].nil? || data[key].is_a?(Integer)
        }

        data["review_rating"].nil? || data["review_rating"].is_a?(Numeric)
      end

      def render_error(error, status)
        render json: { error: error }, status: status
      end
    end
  end
end
