# frozen_string_literal: true

module Api
  module V1
    module Leads
      # POST /api/v1/leads/intake — the website inquiry form lands here.
      # Browser mode (site key + Origin) on day one; relay mode (HMAC)
      # reserved for n8n or any server caller. Contract: docs/leads-intake.md.
      class IntakesController < BaseController
        def preflight
          cors_preflight
        end

        def create
          payload, parse_error = parse_json_body
          return render json: { error: "bad_request" }, status: :bad_request if parse_error
          return render json: { error: "bad_request" }, status: :bad_request unless
            payload.is_a?(Hash) && payload["schema"] == "sherpa.inquiry.v2"

          caller_name = authenticate_intake!
          return if performed?

          contact = payload["contact"].is_a?(Hash) ? payload["contact"] : {}
          email = contact["email"].to_s
          return unless check_rate_limits!(email: email)

          if payload["honeypot"].to_s.present?
            return honeypot_response
          end

          fields = validate_required(payload)
          unless fields
            return render json: { error: "validation", fields: @validation_fields },
              status: :bad_request
          end

          external_ref = "website_form:#{payload['submission_id']}"
          lead = build_lead(payload, fields, external_ref, caller_name)
          existing = nil
          begin
            saved = ::Lead.transaction do
              existing = ::Lead.find_by(external_ref: external_ref)
              next false if existing
              next false unless lead.save

              lead.lead_notifications.create!(event: "email_copy")
              lead.lead_notifications.create!(event: "lead.created")
              Setting.current.update_column(:intake_last_received_at, Time.current)
              true
            end
          rescue ActiveRecord::RecordNotUnique
            existing = ::Lead.find_by(external_ref: external_ref)
            raise unless existing
          end
          existing ||= ::Lead.find_by(external_ref: external_ref) unless saved
          if existing
            Rails.logger.warn(
              "[intake] replay for #{external_ref} lead=#{existing.id} " \
              "body_matches=#{replay_body_matches?(existing, payload, fields)}"
            )
            LeadNotification.enqueue_pending(existing.id)
            return render json: lead_response(existing), status: :ok
          end

          if saved
            LeadNotification.enqueue_pending(lead.id)
            render json: lead_response(lead.reload), status: :accepted
          elsif (field_errors = mappable_field_errors(lead))
            # A second open inquiry from the same email trips the model's
            # uniqueness guard: answer 400 with the field mapped, never 500.
            render json: { error: "validation", fields: field_errors }, status: :bad_request
          else
            Rails.logger.warn("[intake] lead save failed: #{lead.errors.full_messages.to_sentence}")
            render json: { error: "server" }, status: :internal_server_error
          end
        end

        private

        def honeypot_response
          Rails.cache.increment("intake:honeypot:dropped", 1, expires_in: 30.days)
          render json: {
            reference: "SH-#{SecureRandom.alphanumeric(4).upcase}",
            received_at: Time.current.iso8601
          }, status: :accepted
        rescue StandardError
          render json: { error: "server" }, status: :internal_server_error
        end

        # Required: contact.name (2..120), contact.email (shaped + MX/A),
        # consent.contact true, submission_id present. Returns the cleaned
        # fields or nil (setting @validation_fields for the 400 body).
        def validate_required(payload)
          errors = {}
          contact = payload["contact"].is_a?(Hash) ? payload["contact"] : {}
          name = contact["name"].to_s.strip
          errors["contact.name"] = "invalid" if name.length < 2 || name.length > 120

          email = contact["email"].to_s.strip.downcase
          errors["contact.email"] = "invalid" unless valid_email?(email)

          errors["submission_id"] = "invalid" if payload["submission_id"].to_s.strip.blank? ||
            payload["submission_id"].to_s.length > 64

          consent = payload["consent"].is_a?(Hash) ? payload["consent"] : {}
          errors["consent.contact"] = "invalid" unless consent["contact"] == true

          if errors.any?
            @validation_fields = errors
            return nil
          end

          { name: name, email: email }
        end

        def valid_email?(email)
          return false if email.blank? || email.length > 254
          return false unless email.match?(URI::MailTo::EMAIL_REGEXP)

          domain = email.split("@").last.to_s
          return false if domain.blank?
          # Reserved names (RFC 2606) never have MX/A records; reject
          # without a DNS round-trip so the check is deterministic offline.
          return false if domain.downcase.end_with?(".invalid", ".example", ".test", ".localhost")

          begin
            Resolv::DNS.open do |dns|
              mx = dns.getresources(domain, Resolv::DNS::Resource::IN::MX)
              next true if mx.any?

              a = dns.getresources(domain, Resolv::DNS::Resource::IN::A)
              next true if a.any?

              false
            end
          rescue StandardError
            # DNS unreachable from here: fail open so a valid address is
            # never rejected for a resolver outage. Definitive NXDOMAIN
            # still resolves to no records above and rejects.
            true
          end
        end

        def seconds_to_submit(payload)
          timing = payload["timing"].is_a?(Hash) ? payload["timing"] : {}
          started = Time.zone.parse(timing["started_at"].to_s) rescue nil
          submitted = Time.zone.parse(timing["submitted_at"].to_s) rescue nil
          return nil unless started && submitted

          submitted - started
        end

        def build_lead(payload, fields, external_ref, caller_name)
          contact = payload["contact"]
          trip = payload["trip"].is_a?(Hash) ? payload["trip"] : {}
          attribution = payload["attribution"].is_a?(Hash) ? payload["attribution"] : {}
          page = payload["page"].is_a?(Hash) ? payload["page"] : {}
          timing = payload["timing"].is_a?(Hash) ? payload["timing"] : {}
          client_info = payload["client"].is_a?(Hash) ? payload["client"] : {}
          consent = payload["consent"]

          score, hits = ::Leads.suspicion_hits(
            name: fields[:name], email: fields[:email],
            message: payload["message"].to_s,
            seconds_to_submit: seconds_to_submit(payload)
          )
          attribution = attribution.merge("relay" => caller_name) if caller_name != "website_form"

          phone_raw = contact["phone_raw"].to_s.strip.presence
          e164 = phone_raw.to_s.gsub(/[\s\-().]/, "")
          e164 = nil unless e164.match?(/\A\+\d{7,15}\z/)

          placement = payload["placement"].to_s.strip.presence
          placement = nil unless ::Lead::PLACEMENTS.include?(placement)

          lead = ::Lead.new(
            name: fields[:name],
            email: fields[:email],
            phone_raw: phone_raw,
            phone: e164,
            trip_handle: trip["handle"].to_s.strip.presence&.truncate(120),
            trip_title: trip["title"].to_s.strip.presence&.truncate(160),
            message: payload["message"].to_s.strip.presence&.truncate(4000),
            consent_contact_at: (Time.zone.parse(consent["contact_at"].to_s) rescue nil),
            consent_text_version: consent["text_version"].to_s.strip.presence&.truncate(64),
            placement: placement,
            source: ::Leads.derive_source(attribution),
            campaign_name: attribution["utm_campaign"].to_s.strip.presence&.truncate(160),
            external_ref: external_ref,
            spam_score: score,
            status: "new",
            received_at: Time.current,
            metadata: {
              "attribution" => attribution,
              "page" => page,
              "timing" => timing,
              "client" => client_info,
              "suspicion_hits" => hits.map(&:to_s),
              "ip_hash" => Digest::SHA256.hexdigest(request.remote_ip.to_s),
              "user_agent" => request.user_agent.to_s.truncate(300)
            }
          )
          lead.tag_list = ::Lead::SUSPECTED_SPAM_TAG if score.positive?
          lead
        end

        MODEL_FIELD_MAP = { "name" => "contact.name", "email" => "contact.email" }.freeze

        def mappable_field_errors(lead)
          mapped = {}
          lead.errors.each do |error|
            key = MODEL_FIELD_MAP[error.attribute.to_s]
            return nil unless key

            mapped[key] = error.type == :taken ? "taken" : "invalid"
          end
          mapped.presence
        end

        def replay_body_matches?(lead, payload, fields)
          lead.name == fields[:name] && lead.email == fields[:email] &&
            lead.message.to_s == payload["message"].to_s.strip
        end

        def lead_response(lead)
          {
            id: lead.id,
            reference: lead.reference,
            received_at: (lead.received_at || lead.created_at)&.iso8601
          }
        end
      end
    end
  end
end
