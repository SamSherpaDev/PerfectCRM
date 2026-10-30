module ScheduledCallOwner
  extend ActiveSupport::Concern

  def open_scheduled_calls
    if association(:scheduled_calls).loaded?
      scheduled_calls.select { |call| call.persisted? && call.scheduled? && call.scheduled_at.present? }
        .sort_by { |call| [ call.scheduled_at.to_i, call.id.to_i ] }
    else
      scheduled_calls.scheduled.order(:scheduled_at, :id).to_a
    end
  end

  def next_scheduled_call
    open_scheduled_calls.first
  end
end
