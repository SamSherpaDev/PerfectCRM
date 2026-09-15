class Tag < ApplicationRecord
  has_many :taggings, dependent: :destroy

  before_validation :normalize_name

  validates :name, presence: true, uniqueness: { case_sensitive: false }, length: { maximum: 40 }

  scope :ordered, -> { order(:name) }

  private

  def normalize_name
    self.name = name.to_s.strip.downcase.presence || name.to_s.strip
    self.name = name.to_s.strip.downcase if name.present?
  end
end
