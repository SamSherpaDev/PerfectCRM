class TodayController < ApplicationController
  def show
    @summary = Today::Summary.new(
      calendar_date: params[:date],
      calendar_view: params[:view]
    )
  end
end
