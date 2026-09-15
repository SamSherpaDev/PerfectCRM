# frozen_string_literal: true

# Public website-form API. Stateless JSON, no sign-in, no session: the
# storefront and n8n authenticate per request (site key in browser mode,
# HMAC relay signature for server calls). See docs/leads-intake.md.
module Api
  module V1
    class BaseController < ActionController::API
      ALLOWED_ORIGINS = %w[
        https://www.sherpaholidays.com
        https://sherpaholidays.com
      ].freeze
      MAX_BODY_BYTES = 32 * 1024
      RATE_IP_LIMIT = 10
      RATE_IP_WINDOW = 10 * 60
      RATE_EMAIL_LIMIT = 3
      RATE_EMAIL_WINDOW = 60 * 60

      before_action :apply_cors_headers

      private

      def apply_cors_headers
        origin = request.headers["Origin"].to_s
        if ALLOWED_ORIGINS.include?(origin)
          response.headers["Access-Control-Allow-Origin"] = origin
          response.headers["Vary"] = "Origin"
        end
      end

      def cors_preflight
        origin = request.headers["Origin"].to_s
        if ALLOWED_ORIGINS.include?(origin)
          response.headers["Access-Control-Allow-Origin"] = origin
          response.headers["Vary"] = "Origin"
          response.headers["Access-Control-Allow-Methods"] = "POST, OPTIONS"
          response.headers["Access-Control-Allow-Headers"] = "Content-Type, X-Sherpa-Site-Key"
          response.headers["Access-Control-Max-Age"] = "86400"
        end
        head :no_content
      end

      def raw_body
        body = request.raw_post
        body = body.to_s.dup.force_encoding(Encoding::UTF_8)
        body.scrub
      end

      def relay_caller
        @relay_caller ||= ::Leads.verify_relay_signature(
          raw_body, request.headers["X-Sherpa-Signature"],
          secret: Setting.current.ensure_intake_credentials!.relay_secret
        )
      end

      # Browser mode: public site key + allowlisted Origin. Relay mode:
      # HMAC signature, no Origin check. Renders the error and returns nil
      # when authentication fails.
      def authenticate_intake!
        caller_name = relay_caller
        if request.headers["X-Sherpa-Signature"].present?
          return render_unauthorized unless caller_name

          touch_relay_use!
          return caller_name
        end

        settings = Setting.current.ensure_intake_credentials!
        unless settings.site_key.present? &&
            Rack::Utils.secure_compare(settings.site_key, request.headers["X-Sherpa-Site-Key"].to_s)
          return render json: { error: "forbidden" }, status: :forbidden
        end
        unless ALLOWED_ORIGINS.include?(request.headers["Origin"].to_s)
          return render json: { error: "forbidden" }, status: :forbidden
        end

        settings.update_column(:site_key_last_used_at, Time.current)
        "website_form"
      end

      def authenticate_relay_only!
        caller_name = relay_caller
        return render_unauthorized unless caller_name

        touch_relay_use!
        caller_name
      end

      def render_unauthorized
        render json: { error: "unauthorized" }, status: :unauthorized
        nil
      end

      def touch_relay_use!
        Setting.current.update_column(:relay_last_used_at, Time.current)
      rescue ActiveRecord::StatementInvalid
        nil
      end

      # 10 per IP per 10 minutes, 3 per email per hour. Renders 429 with
      # Retry-After and returns false when over the limit.
      def check_rate_limits!(email: nil, namespace: "intake")
        ip_retry = ::Leads.rate_limit_exceeded?(
          "intake-rate:#{namespace}:ip:#{request.remote_ip}",
          limit: RATE_IP_LIMIT, window: RATE_IP_WINDOW
        )
        if ip_retry
          return render_rate_limited(ip_retry)
        end

        normalized = email.to_s.strip.downcase
        if normalized.present?
          email_retry = ::Leads.rate_limit_exceeded?(
            "intake-rate:#{namespace}:email:#{normalized}",
            limit: RATE_EMAIL_LIMIT, window: RATE_EMAIL_WINDOW
          )
          return render_rate_limited(email_retry) if email_retry
        end
        true
      end

      def render_rate_limited(retry_after)
        response.headers["Retry-After"] = retry_after.to_s
        render json: { error: "rate_limited" }, status: :too_many_requests
        false
      end

      def parse_json_body
        raw = raw_body
        return [ nil, :too_large ] if raw.bytesize > MAX_BODY_BYTES

        [ JSON.parse(raw), nil ]
      rescue JSON::ParserError
        [ nil, :bad_request ]
      end
    end
  end
end
