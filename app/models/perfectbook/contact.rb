# Mirror of PerfectBook contacts (customers, advisors, partners).
# Read-only locally: replaced by PerfectBook::SyncContactsJob, never edited.
# Phone is always null from the API today; the column stays for the contract.
module PerfectBook
  class Contact < ApplicationRecord
    validates :perfectbook_id, presence: true, uniqueness: true

    def archived?
      archived
    end
  end
end
