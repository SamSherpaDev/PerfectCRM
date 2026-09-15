# Mirror of PerfectBook departures for the quote builder. Read-only
# locally: replaced by PerfectBook::SyncCatalogJob, never edited here.
module PerfectBook
  class Departure < ApplicationRecord
    serialize :country_codes, coder: JSON

    validates :perfectbook_id, presence: true, uniqueness: true
  end
end
