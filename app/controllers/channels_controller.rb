class ChannelsController < ApplicationController
  def index
    @summary = WeeklyReport::Summary.new
    @snapshots = ChannelSnapshot.latest_by_channel
  end
end
