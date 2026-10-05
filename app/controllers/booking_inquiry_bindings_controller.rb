class BookingInquiryBindingsController < ApplicationController
  def create
    booking = PerfectBook::Booking.find(params[:booking_id])
    attributes = params.require(:binding)
    raise ArgumentError, "Choose an inquiry for this PerfectBook contact" if attributes[:lead_id].blank?
    lead = Lead.find(attributes[:lead_id])
    reason = attributes[:reason].to_s.strip.first(240)
    raise ArgumentError, "Enter the evidence/reason for this review" if reason.blank?
    BookingInquiryBinding.link!(booking, lead: lead, actor: Current.user_email, evidence: reason, reason: reason)
    redirect_to lead_path(lead), notice: "Booking inquiry link reviewed.", status: :see_other
  rescue ArgumentError => error
    redirect_back fallback_location: settings_weekly_report_path, alert: error.message, status: :see_other
  rescue ActiveRecord::RecordInvalid => error
    redirect_back fallback_location: settings_weekly_report_path, alert: error.record.errors.full_messages.to_sentence, status: :see_other
  end
end
