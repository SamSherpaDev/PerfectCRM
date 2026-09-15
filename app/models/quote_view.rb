# One logged view of the public tap-to-accept page. IPs are stored as a
# SHA256 digest, never raw, and rows exist only for rate-limiting.
class QuoteView < ApplicationRecord
  belongs_to :quote

  validates :ip_digest, presence: true

  def self.digest(ip)
    Digest::SHA256.hexdigest(ip.to_s)
  end
end
