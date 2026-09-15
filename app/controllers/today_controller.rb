class TodayController < ApplicationController
  def show
    @summary = Today::Summary.new
  end
end
