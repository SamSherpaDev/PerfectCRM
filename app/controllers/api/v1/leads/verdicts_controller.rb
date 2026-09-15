# frozen_string_literal: true

module Api
  module V1
    module Leads
      # POST /api/v1/leads/:id/verdict — Panda AI (or n8n on its behalf)
      # reports a fit score and may move the lead between New, Chatting and
      # Lost. Relay mode only. Quoted, nudged, won and conversion stay
      # manual: anything else is rejected. Contract: docs/leads-intake.md.
      class VerdictsController < BaseController
        def create
          caller_name = authenticate_relay_only!
          return if performed?

          payload, parse_error = parse_json_body
          return render json: { error: "bad_request" }, status: :bad_request if parse_error
          return render json: { error: "bad_request" }, status: :bad_request unless payload.is_a?(Hash)

          lead = ::Lead.find_by(id: params[:id])
          return render json: { error: "not_found" }, status: :not_found unless lead
          if lead.converted?
            return render json: { error: "validation", fields: { "base" => "converted" } },
              status: :unprocessable_entity
          end

          errors = {}
          score = payload["fit_score"]
          if !score.nil? && !(score.is_a?(Integer) && score.between?(0, 100))
            errors["fit_score"] = "invalid"
          end

          band = payload["fit_band"]&.to_s
          if band.present? && !band.in?(::Lead::FIT_BANDS)
            errors["fit_band"] = "invalid"
          end

          status = payload["status"]&.to_s
          if status.present? && !status.in?(::Lead::AUTOMATION_STATUSES)
            errors["status"] = "invalid"
          end

          if errors.any?
            return render json: { error: "validation", fields: errors },
              status: :unprocessable_entity
          end

          from_status = lead.status
          lead.fit_score = score unless score.nil?
          lead.fit_band = band if band.present?
          lead.fit_reason = payload["fit_reason"].to_s.strip.presence&.truncate(1000) if payload.key?("fit_reason")
          lead.status = status if status.present?
          lead.save!

          record_automation_event!(lead, caller_name, from_status: from_status)
          render json: {
            reference: lead.reload.reference,
            status: lead.status,
            fit_score: lead.fit_score,
            fit_band: lead.fit_band
          }, status: :ok
        end

        private

        def record_automation_event!(lead, caller_name, from_status:)
          parts = []
          parts << "scored #{lead.fit_score}#{lead.fit_band.present? ? " (#{lead.fit_band.humanize})" : ''}" if lead.saved_change_to_fit_score? || lead.saved_change_to_fit_band?
          if lead.saved_change_to_status?
            parts << "moved from #{from_status.humanize} to #{lead.status.humanize}"
          end
          summary = "#{caller_name.humanize} #{parts.any? ? parts.join(' and ') : 'checked in on'} this lead"
          lead.activity_events.create!(
            kind: "automation",
            summary: summary,
            occurred_at: Time.current,
            metadata: {
              "caller" => caller_name,
              "fit_score" => lead.fit_score,
              "fit_band" => lead.fit_band,
              "from_status" => from_status,
              "to_status" => lead.status
            }
          )
        end
      end
    end
  end
end
