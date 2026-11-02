# The automatic "Your Nepal itinerary" email as the visitor receives it
# (README.md, "Leads"), so the owner can read the wording before switching
# it on in Settings > Automations. Shows the sample trip by default, or a
# real itinerary designer inquiry with ?lead_id=.
class ItineraryEmailsController < ApplicationController
  def show
    @settings = Setting.current
    @lead = Lead.find_by(id: params[:lead_id]) if params[:lead_id].present?
    @lead = nil unless @lead&.itinerary
    if @lead
      @call_requested = @lead.call_request.present?
      @recipient = @lead.email
      @content = ItineraryEmail.content_for(@lead)
    else
      @call_requested = params[:call] != "0"
      @recipient = "traveler@example.com"
      @content = ItineraryEmail.content(first_name: "Alex", itinerary: ItineraryEmail::SAMPLE_ITINERARY,
        call_request: (ItineraryEmail::SAMPLE_CALL_REQUEST if @call_requested))
    end
  end
end
