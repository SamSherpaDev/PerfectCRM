# Aggregate channel checks only. Fixed action text prevents personal data from
# entering the tracker; the JSON contract is in docs/channel-checks.md.
class ChannelSnapshot < ApplicationRecord
  CHANNELS = {
    "youtube" => "YouTube",
    "tiktok" => "TikTok",
    "tripadvisor" => "TripAdvisor",
    "google_business_profile" => "Google Business Profile",
    "instagram" => "Instagram",
    "facebook" => "Facebook",
    "google_ads" => "Google Ads",
    "meta_ads" => "Meta ads"
  }.freeze
  OPEN_ITEM_TEXTS = [
    "Review new reviews", "Review new comments", "Check profile details",
    "Review scheduled posts", "Review video details", "Review campaign performance",
    "Check account access", "Check billing status"
  ].freeze
  MAX_OPEN_ITEMS = 8
  MAX_ITEM_LENGTH = 80
  MAX_COUNT = 1_000_000_000

  validates :channel, inclusion: { in: CHANNELS.keys }
  validates :checked_at, presence: true
  validates :review_count, :follower_count, :inquiries, numericality: {
    only_integer: true, greater_than_or_equal_to: 0, less_than_or_equal_to: MAX_COUNT,
    allow_nil: true
  }
  validates :inquiries, absence: true, if: -> { AdSpend::SOURCES.include?(channel) }
  validates :review_rating, numericality: {
    greater_than_or_equal_to: 1, less_than_or_equal_to: 5, allow_nil: true
  }
  validate :aggregate_open_items
  validate :plausible_check_time
  validate :rating_has_reviews

  def self.latest_by_channel
    # The check time, not arrival time, wins when a worker submits a late check.
    # One indexed lookup per channel, each with id as the tie-breaker.
    CHANNELS.keys.index_with { |channel| where(channel: channel).order(checked_at: :desc, id: :desc).first }
  end

  def open_item_count = open_items.size

  private

  def aggregate_open_items
    unless open_items.is_a?(Array) && open_items.size <= MAX_OPEN_ITEMS &&
        open_items.uniq.size == open_items.size && open_items.all? { |text|
          text.is_a?(String) && text.length <= MAX_ITEM_LENGTH && OPEN_ITEM_TEXTS.include?(text)
        }
      errors.add(:open_items, "must be a unique list of allowed aggregate actions (up to #{MAX_OPEN_ITEMS})")
    end
  end

  def plausible_check_time
    return unless checked_at

    errors.add(:checked_at, "must not be in the future") if checked_at > 5.minutes.from_now
  end

  def rating_has_reviews
    if review_rating.present? && review_count.to_i.zero?
      errors.add(:review_rating, "requires a positive review count")
    end
  end
end
