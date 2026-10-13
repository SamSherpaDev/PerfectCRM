module Api
  module V1
    class DailyChannelSpendsController < ChannelChecksController
      MAX_BODY_BYTES = 64 * 1024
      FIELDS = %w[spent_on source campaign_id campaign_name currency amount_minor].freeze
      AD_FIELDS = %w[ad_id ad_name].freeze

      def create
        return render_error("json_required", :unsupported_media_type) unless request.media_type == "application/json"
        raw = request.body.read(MAX_BODY_BYTES + 1)
        return render_error("too_large", :content_too_large) if raw.bytesize > MAX_BODY_BYTES
        data = JSON.parse(raw)
        rows = data["spends"] if data.is_a?(Hash) && data.keys == [ "spends" ]
        unless rows.is_a?(Array) && rows.size.between?(1, 100) && rows.all? { |row| valid_row?(row) }
          return render_error("invalid_spend", :unprocessable_entity)
        end
        entries = DailyAdSpend.transaction do
          rows.map { |row| DailyAdSpend.record!(**row.symbolize_keys) }
        end
        render json: { entries: entries.size }, status: :created
      rescue JSON::ParserError
        render_error("invalid_json", :bad_request)
      rescue ActiveRecord::RecordInvalid, Date::Error, RangeError
        render_error("invalid_spend", :unprocessable_entity)
      end

      private

      def valid_row?(row)
        return false unless row.is_a?(Hash) && (FIELDS - row.keys).empty? && (row.keys - FIELDS - AD_FIELDS).empty?
        return false unless row["amount_minor"].is_a?(Integer)
        return false unless row.except("amount_minor").values.all? { |value| value.is_a?(String) }
        return false if row.key?("ad_id") && row["ad_id"].strip.blank?
        return false if row.key?("ad_name") && !row.key?("ad_id")
        return false unless row["spent_on"].match?(/\A\d{4}-\d{2}-\d{2}\z/)
        date = Date.iso8601(row["spent_on"])
        (Date.current - 2.years..Date.current - 1).cover?(date)
      rescue Date::Error
        false
      end
    end
  end
end
