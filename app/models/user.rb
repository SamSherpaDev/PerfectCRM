class User < ApplicationRecord
  validates :google_sub, presence: true, uniqueness: true
  validates :email, presence: true

  def self.allowed_email?(email)
    email.present? && ENV.fetch("ALLOWED_GOOGLE_EMAILS", "").split(",").map { |value| value.strip.downcase }.include?(email.downcase)
  end
end
