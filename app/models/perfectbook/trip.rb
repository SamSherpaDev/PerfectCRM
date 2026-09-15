# Mirror of PerfectBook's trip catalog. Read-only locally: rows are
# replaced by PerfectBook::SyncCatalogJob and never edited in the CRM.
# See README.md, "PerfectBook connection", for the ownership contract.
module PerfectBook
  class Trip < ApplicationRecord
    serialize :departure_ids, coder: JSON

    validates :perfectbook_id, presence: true, uniqueness: true
  end
end
