# Short-lived holding area for sensitive attachments that arrive by email.
#
# The ingester keeps the bytes here (Active Storage on the same private
# bucket as every other attachment) purely so the captain can hand the
# file to PerfectBook through DocumentHandoffs. Holdings never get a
# timeline download link, purge on hand-off or 24 hours after arrival,
# and are swept hourly by DocumentHoldingsPurgeJob. PerfectBook stays
# the only long-term store for traveler documents; see README, "Mail".
class DocumentHolding < ApplicationRecord
  HOLD_HOURS = 24
  # PerfectBook's upload endpoint caps files at 10 MB; larger arrivals
  # stay metadata-only placeholders and never enter the holding area.
  MAX_BYTES = 10 * 1024 * 1024

  belongs_to :message, class_name: "::Message"

  has_one_attached :file

  validates :filename, presence: true
  validates :expires_at, presence: true

  scope :expired, -> { where(expires_at: ...Time.current) }
  scope :live, -> { where(expires_at: Time.current...) }

  # Bytes for one sensitive arrival, expiring 24 hours later. Returns nil
  # (metadata-only placeholder) when the file is too large to hand off.
  def self.hold!(message:, filename:, content_type:, data:)
    return nil if data.bytesize > MAX_BYTES

    holding = create!(message: message, filename: filename, content_type: content_type,
      byte_size: data.bytesize, expires_at: HOLD_HOURS.hours.from_now)
    holding.file.attach(io: StringIO.new(data), filename: filename, content_type: content_type)
    holding
  end

  def live?
    expires_at.future?
  end

  # Delete the bytes and the row. The caller's placeholder entry on the
  # message is updated separately (hand-off removes it, expiry marks it).
  def purge!
    file.purge if file.attached?
    destroy!
  end

  # Sweep expired holdings: drop their bytes, then mark their timeline
  # placeholders expired so the thread still explains what arrived.
  def self.purge_expired!
    expired.find_each do |holding|
      message = holding.message
      holding_id = holding.id
      holding.purge!
      message&.mark_holding_expired!(holding_id)
    rescue ActiveRecord::RecordNotFound
      next
    end
  end
end
