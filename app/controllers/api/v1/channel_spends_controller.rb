module Api
  module V1
    class ChannelSpendsController < ChannelChecksController
      MAX_BODY_BYTES = 16 * 1024
      FIELDS = %w[channel week_start campaigns].freeze
      CAMPAIGN_FIELDS = %w[campaign_name amount_dollars].freeze

      def create
        return render_error("json_required", :unsupported_media_type) unless request.media_type == "application/json"

        raw = request.body.read(MAX_BODY_BYTES + 1)
        return render_error("too_large", :content_too_large) if raw.bytesize > MAX_BODY_BYTES

        body = JSON.parse(raw)
        unless body.is_a?(Hash) && body.keys == [ "spend" ] && valid_shape?(body["spend"])
          return render_error("invalid_spend", :unprocessable_entity)
        end

        attributes = body.fetch("spend")
        week = Date.iso8601(attributes.fetch("week_start"))
        last_week = WeeklyReport::Summary.last_complete_week
        unless week.monday? && (last_week - 7 * 7..last_week).cover?(week)
          return render_error("invalid_spend", :unprocessable_entity)
        end

        entries = AdSpend.transaction do
          attributes.fetch("campaigns").map do |campaign|
            AdSpend.record!(week_start: week, source: attributes.fetch("channel"),
              campaign_name: campaign.fetch("campaign_name"), amount_dollars: campaign.fetch("amount_dollars"))
          end.index_by(&:id).values
        end
        render json: { entries: entries.map { |entry|
          { channel: entry.source, week_start: entry.week_start.iso8601,
            campaign_name: entry.campaign_name, amount_dollars: format("%d.%02d", *entry.amount_minor.divmod(100)) }
        } }, status: :created
      rescue JSON::ParserError
        render_error("invalid_json", :bad_request)
      rescue Date::Error, RangeError
        render_error("invalid_spend", :unprocessable_entity)
      rescue ActiveRecord::RecordInvalid => e
        render json: { error: "invalid_spend", fields: e.record.errors.attribute_names }, status: :unprocessable_entity
      end

      private

      def valid_shape?(data)
        return false unless data.is_a?(Hash) && data.keys.sort == FIELDS.sort
        return false unless AdSpend::SOURCES.include?(data["channel"])
        return false unless data["week_start"].is_a?(String) && data["week_start"].match?(/\A\d{4}-\d{2}-\d{2}\z/)
        return false unless data["campaigns"].is_a?(Array) && data["campaigns"].any?

        data["campaigns"].all? do |campaign|
          next false unless campaign.is_a?(Hash) && campaign.keys.sort == CAMPAIGN_FIELDS.sort
          next false unless campaign["campaign_name"].is_a?(String)

          amount = campaign["amount_dollars"]
          (amount.is_a?(String) || amount.is_a?(Numeric)) && amount.to_s.match?(AdSpend::AMOUNT_FORMAT)
        end
      end
    end
  end
end
