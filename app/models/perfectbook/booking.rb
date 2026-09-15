# Mirror of one PerfectBook booking plus its invoice badge. Read-only
# locally: replaced by PerfectBook::SyncBookingsJob, never edited here.
# TODO: record an ActivityEvent when status or invoice_badge changes, once
# that model lands on main (no such model yet, so syncs stay silent).
module PerfectBook
  class Booking < ApplicationRecord
    validates :perfectbook_id, presence: true, uniqueness: true
    validates :perfectbook_contact_id, presence: true
  end
end
