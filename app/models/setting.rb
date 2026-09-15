class Setting < ApplicationRecord
  APPEARANCES = %w[paper night].freeze

  validates :singleton_key, inclusion: { in: [ 1 ] }, uniqueness: true
  validates :appearance, inclusion: { in: APPEARANCES }

  def self.current
    find_by(singleton_key: 1) || create_or_find_by!(singleton_key: 1)
  end
end
