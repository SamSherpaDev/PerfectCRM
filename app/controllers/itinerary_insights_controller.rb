# What itinerary designer visitors built, one month at a time
# (Leads::ItineraryInsights, README.md "Leads").
class ItineraryInsightsController < ApplicationController
  def show
    @insights = Leads::ItineraryInsights.new(month: requested_month)
    @current_month = Date.current.beginning_of_month
  end

  private

  # A month on or before this one; anything else falls back to this month.
  def requested_month
    date = Date.strptime(params[:month].to_s, "%Y-%m").beginning_of_month
    date > Date.current ? Date.current.beginning_of_month : date
  rescue Date::Error
    Date.current.beginning_of_month
  end
end
