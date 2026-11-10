# Recurring sweep (every 5 minutes, see config/recurring.yml): marks outbound
# messages stuck in "sending" for more than 15 minutes as failed so an
# interrupted deploy or worker restart cannot leave a reply saying "Sending…"
# forever. Never resends automatically; the owner checks Sent Items first.
class OutboundDeliverySweepJob < ApplicationJob
  queue_as :default

  def perform
    Message.fail_stuck_sending!
  end
end
