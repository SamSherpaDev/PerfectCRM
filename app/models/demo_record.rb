class DemoRecord < ApplicationRecord
  validates :record_type, :record_id, presence: true
  validates :record_id, uniqueness: { scope: :record_type }
end
