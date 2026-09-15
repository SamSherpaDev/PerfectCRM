class Ai::PruneCallsJob < ApplicationJob
  queue_as :default

  def perform
    AiCall.expired.delete_all
  end
end
