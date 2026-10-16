class ChannelsController < ApplicationController
  def index
    @summary = WeeklyReport::Summary.new
    @snapshots = ChannelSnapshot.latest_by_channel
    @daily_spend_statuses = SpendStatus.daily_period(start_date: Date.current.beginning_of_month, end_date: Date.yesterday)
  end
end
