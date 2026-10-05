# frozen_string_literal: true

module Api
  module V1
    module Leads
      # POST /api/v1/leads/intake/details — the optional step-two answers
      # (when, how many, budget) posted after a successful send. Same auth
      # and CORS as intake; separate IP limit, no email limit.
      # Contract: docs/leads-intake.md.
      class DetailsController < BaseController
        def preflight
          cors_preflight
        end

        def create
          payload, parse_error = parse_json_body
          return render json: { error: "bad_request" }, status: :bad_request if parse_error
          return render json: { error: "bad_request" }, status: :bad_request unless
            payload.is_a?(Hash) && payload["schema"] == "sherpa.inquiry.details.v1"

          authenticate_intake!
          return if performed?
          return unless check_rate_limits!(namespace: "details")

          submission_id = payload["submission_id"].to_s.strip
          if submission_id.blank?
            return render json: { error: "validation", fields: { "submission_id" => "invalid" } },
              status: :bad_request
          end

          lead = ::Lead.find_by(external_ref: "website_form:#{submission_id}")
          return render json: { error: "not_found" }, status: :not_found unless lead

          received = lead.received_at || lead.created_at
          if received && received < 24.hours.ago
            return render json: { error: "expired" }, status: :gone
          end
          updates, errors = extract_updates(payload)
          answer = payload["source_answer"]
          if payload.key?("source_answer")
            if !answer.is_a?(Hash) || !::SourceHistory::ANSWERS.key?(answer["code"]) ||
                (answer["detail"].present? && (!answer["detail"].is_a?(String) || answer["detail"].length > 240)) ||
                (answer["question_version"].present? && answer["question_version"] != ::SourceHistory::QUESTION_VERSION)
              errors["source_answer"] = "invalid"
            end
          end
          begin
            acquisition = ::Leads::Acquisition.parse(payload)
          rescue ArgumentError => error
            errors[error.message] = "invalid"
          end
          if errors.any?
            return render json: { error: "validation", fields: errors }, status: :bad_request
          end

          lead.with_lock do
            if lead.converted?
              return render json: { error: "converted" }, status: :unprocessable_entity
            end
            if lead.archived?
              return render json: { error: "archived" }, status: :unprocessable_entity
            end

            lead.assign_attributes(updates)
            if answer
              detail = answer["detail"].to_s.strip.presence
              if lead.source_confirmed_at.present?
                unless lead.reported_source_code == answer["code"] && lead.reported_source_detail == detail
                  return render json: { error: "validation", fields: { "source_answer" => "confirmed" } }, status: :unprocessable_entity
                end
              else
                lead.source_collection_method = "website_form"
                lead.source_choice = answer["code"]
                lead.reported_source_detail = detail
              end
            end
            if acquisition
              previous = (lead.metadata || {})["acquisition"] || {}
              incoming_permission = acquisition["permission"]
              previous_permission = previous["permission"] || {}
              incoming_at = Time.iso8601(incoming_permission["observed_at"] || incoming_permission["recorded_at"])
              previous_at = previous_permission["observed_at"] || previous_permission["recorded_at"]
              if previous_at
                previous_at = Time.iso8601(previous_at)
                conflicting = incoming_permission.except("recorded_at", "observed_at") != previous_permission.except("recorded_at", "observed_at")
                if incoming_at < previous_at || (incoming_at == previous_at && conflicting &&
                    incoming_permission["observed_at"].present? && previous_permission["observed_at"].present?)
                  return render json: { error: "validation", fields: { "acquisition.permission" => "stale" } }, status: :unprocessable_entity
                end
              end
              acquisition = previous.merge(acquisition)
              acquisition["first_touch"] = previous["first_touch"] if ::Leads::Acquisition.eligible?(previous["first_touch"])
              acquisition["permission"]["recorded_at"] = previous.dig("permission", "recorded_at") if
                acquisition["permission"].except("recorded_at") == (previous["permission"] || {}).except("recorded_at")
              if acquisition.dig("permission", "state") != "allowed" || acquisition.dig("permission", "opted_out") == true
                ::Leads::Acquisition::TOUCHES.each { |key| acquisition[key] = { "unknown_reason" => "declined_permission" } }
                acquisition.delete("submission_page")
                lead.metadata = (lead.metadata || {}).except("page")
                lead.campaign_name = nil
                lead.source = "website_form" if %w[google_ads meta_ads].include?(lead.source)
              end
              lead.metadata = (lead.metadata || {}).merge("acquisition" => acquisition,
                "attribution" => ::Leads::Acquisition.legacy_attribution((lead.metadata || {})["attribution"] || {}, acquisition: acquisition))
            end
            if lead.changed?
              unless lead.save
                fields = lead.errors.map { |error| [ error.attribute, "invalid" ] }.to_h
                return render json: { error: "validation", fields: fields }, status: :unprocessable_entity
              end
              lead.notes.create!(
                body: "Details added by the visitor at #{Time.current.strftime('%-b %-d, %Y, %-I:%M %p')}."
              )
              lead.lead_notifications.create!(event: "lead.details_added")
            end
          end
          LeadNotification.enqueue_pending(lead.id)
          render json: { reference: lead.reload.reference }, status: :ok
        end

        private

        # Only provided fields are touched. Unknown budget bands and
        # out-of-range values are 400s, never silent drops.
        def extract_updates(payload)
          updates = {}
          errors = {}
          trip = payload["trip"].is_a?(Hash) ? payload["trip"] : {}
          party = payload["party"].is_a?(Hash) ? payload["party"] : {}

          if trip.key?("month")
            month = trip["month"]
            if month.nil?
              updates["travel_month"] = nil
            elsif month.is_a?(Integer) && month.between?(1, 12)
              updates["travel_month"] = month
            else
              errors["trip.month"] = "invalid"
            end
          end

          if trip.key?("year")
            year = trip["year"]
            if year.nil?
              updates["travel_year"] = nil
            elsif year.is_a?(Integer) && year.between?(2020, 2100)
              updates["travel_year"] = year
            else
              errors["trip.year"] = "invalid"
            end
          end

          if trip.key?("timing_unknown")
            value = trip["timing_unknown"]
            if value.in?([ true, false ])
              updates["timing_unknown"] = value
            else
              errors["trip.timing_unknown"] = "invalid"
            end
          end

          if trip.key?("budget_band")
            band = trip["budget_band"]
            if band.nil?
              updates["budget_band"] = nil
            elsif band.to_s.in?(::Lead::BUDGET_BANDS)
              updates["budget_band"] = band.to_s
            else
              errors["trip.budget_band"] = "invalid"
            end
          end

          if party.key?("size")
            size = party["size"]
            if size.nil?
              updates["party_size"] = nil
            elsif size.is_a?(Integer) && size.between?(1, 20)
              updates["party_size"] = size
            else
              errors["party.size"] = "invalid"
            end
          end

          [ updates, errors ]
        end
      end
    end
  end
end
