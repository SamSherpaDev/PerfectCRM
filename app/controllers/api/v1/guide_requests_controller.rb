module Api
  module V1
    class GuideRequestsController < BaseController
      MAX_BODY_BYTES = 2048
      FIELDS = %w[schema email source honeypot].freeze

      def preflight
        cors_preflight
      end

      def create
        return unavailable unless PrivateNepalGuide.available?
        return forbidden unless browser_authorized?

        payload, error = parse_json_body
        return render json: { error: "bad_request" }, status: :bad_request if error || !payload.is_a?(Hash)

        errors = validation_errors(payload)
        return render json: { error: "validation", fields: errors }, status: :bad_request if errors.any?

        email = payload["email"].strip.downcase
        # Keep raw email out of the rate-limit key; the receipt owns its one copy.
        return unless check_rate_limits!(email: Digest::SHA256.hexdigest(email), namespace: "guide-request-v1")

        receipt = GuideRequest.accept!(email: email, source: payload["source"])
        receipt.enqueue_delivery!
        response.headers["Cache-Control"] = "no-store"
        render json: { schema: "sherpa.guide-receipt.v1", status: "accepted" }, status: :accepted
      rescue PrivateNepalGuide::Unavailable, ActiveRecord::ActiveRecordError, ActiveJob::EnqueueError => error
        Rails.logger.warn("[guide-request] unavailable (#{error.class})")
        unavailable
      end

      private

      # Browser-only, using the existing public site identifier without rotating
      # credentials or touching the protected inquiry authentication path.
      def browser_authorized?
        key = Setting.current.site_key
        ALLOWED_ORIGINS.include?(request.headers["Origin"].to_s) && key.present? &&
          Rack::Utils.secure_compare(key, request.headers["X-Sherpa-Site-Key"].to_s) &&
          request.headers["X-Sherpa-Signature"].blank?
      end

      def forbidden
        render json: { error: "forbidden" }, status: :forbidden
      end

      def unavailable
        render json: { error: "unavailable" }, status: :service_unavailable
      end

      def validation_errors(payload)
        errors = {}
        errors["schema"] = "invalid" unless payload["schema"] == "sherpa.guide-request.v1"
        errors["source"] = "invalid" unless payload["source"] == "trip_quiz_result"
        errors["fields"] = "unknown" if (payload.keys - FIELDS).any?
        errors["honeypot"] = "invalid" if payload["honeypot"].present?
        email = payload["email"]
        unless email.is_a?(String) && email.strip.length.between?(3, 254) && !email.match?(/[\r\n]/) &&
            !email.strip.match?(/[\s,;<>]/) && email.strip.match?(URI::MailTo::EMAIL_REGEXP)
          errors["email"] = "invalid"
        end
        errors
      end

      # A smaller bound than inquiry payloads, without changing their parser.
      def parse_json_body
        return [ nil, :too_large ] if request.raw_post.bytesize > MAX_BODY_BYTES

        super
      end
    end
  end
end
