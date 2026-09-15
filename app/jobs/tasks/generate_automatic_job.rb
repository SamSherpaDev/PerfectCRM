# Daily proposer: review asks, repeat-trip nudges, and deposit nudges from
# the mirrored PerfectBook bookings. Creates tasks the captain acts on;
# never sends mail.
module Tasks
  class GenerateAutomaticJob < ApplicationJob
    queue_as :default

    def perform(today: Date.current)
      Tasks::Automatic.run!(today: today)
    end
  end
end
