class SourceBackfillBatch < ApplicationRecord
  serialize :reconciliation_json, coder: JSON
  validates :digest, presence: true, uniqueness: true
  validates :reviewer, presence: true
end
