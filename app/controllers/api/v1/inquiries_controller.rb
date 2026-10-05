module Api
  module V1
    class InquiriesController < ActionController::API
      def show
        expected = ENV["PERFECTBOOK_INQUIRY_TOKEN"].to_s
        supplied = request.headers["Authorization"].to_s
        unless expected.present? && supplied.start_with?("Bearer ") &&
            ActiveSupport::SecurityUtils.secure_compare(expected, supplied.delete_prefix("Bearer "))
          return render json: { error: "unauthorized" }, status: :unauthorized
        end
        lead = Lead.find_by(reference: params[:reference])
        return render json: { error: "not_found" }, status: :not_found unless lead

        render json: { crm_inquiry_ref: lead.reference,
          perfectbook_contact_ids: [ lead.perfectbook_contact_id, lead.converted_client&.perfectbook_contact_id,
            lead.existing_client&.perfectbook_contact_id ].compact.uniq,
          trip_title: lead.trip_title, trip_interest: lead.trip_interest,
          travel_month: lead.travel_month, travel_year: lead.travel_year }
      end
    end
  end
end
