# Retained even if the inbound message is removed: Graph replays must not
# alert twice about the same provider id.
class ReplyAlertReservation < ApplicationRecord
  belongs_to :message, optional: true
end
