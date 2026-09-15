class QuoteTripPreference < ApplicationRecord
  validates :perfectbook_trip_id, presence: true, uniqueness: true
end
