# The automatic "Your Nepal itinerary" email as the visitor receives it
# (README.md, "Leads"), so the owner can read the wording before switching
# it on in Settings > Automations. Shows the sample trip with or without a
# call request (?call=0).
class ItineraryEmailsController < ApplicationController
  def show
    @settings = Setting.current
    @call_requested = params[:call] != "0"
    @content = ItineraryEmail.content(first_name: "Alex", itinerary: ItineraryEmail::SAMPLE_ITINERARY,
      call_request: (ItineraryEmail::SAMPLE_CALL_REQUEST if @call_requested))
  end
end
