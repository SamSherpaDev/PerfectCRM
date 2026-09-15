class Message < ApplicationRecord
  DIRECTIONS = %w[in out].freeze

  belongs_to :conversation, inverse_of: :messages
  has_many_attached :files

  serialize :to_addresses, coder: JSON
  serialize :cc_addresses, coder: JSON
  serialize :gmail_labels, coder: JSON
  serialize :attachment_notices, coder: JSON

  validates :direction, inclusion: { in: DIRECTIONS }
  validates :gm_message_id, uniqueness: { allow_nil: true }

  scope :inbound, -> { where(direction: "in") }
  scope :outbound, -> { where(direction: "out") }
  scope :unread, -> { where(direction: "in", read_at: nil) }
  scope :newest_first, -> { order(sent_at: :desc, id: :desc) }
  scope :oldest_first, -> { order(sent_at: :asc, id: :asc) }

  after_create :bump_conversation
  after_destroy :rebalance_conversation

  def self.sensitive_attachment?(filename, content_type)
    "#{filename} #{content_type}".match?(/passport|visa|insurance|identity|(?:\A|[^a-z])id(?:[^a-z]|\z)|scan/i)
  end

  def inbound?
    direction == "in"
  end

  def outbound?
    direction == "out"
  end

  def unread?
    inbound? && read_at.nil?
  end

  def mark_read!
    return unless unread?

    update!(read_at: Time.current)
    conversation.refresh_counters!
  end

  # Plain-text preview for lists: stored text body, else stripped HTML.
  def preview_text(limit = 140)
    text = text_body.presence || ActionView::Base.full_sanitizer.sanitize(html_body.to_s).squish
    text.truncate(limit)
  end

  def to_list
    Array(to_addresses).reject(&:blank?)
  end

  def cc_list
    Array(cc_addresses).reject(&:blank?)
  end

  def label_list
    Array(gmail_labels).reject(&:blank?)
  end

  private

  def bump_conversation
    conversation.refresh_counters!
    touch_linkable
  rescue ActiveRecord::RecordNotFound
    nil
  end

  def rebalance_conversation
    conversation.refresh_counters!
  rescue ActiveRecord::RecordNotFound
    nil
  end

  def touch_linkable
    target = conversation.linkable
    target.touch_activity! if target&.respond_to?(:touch_activity!)
  rescue NoMethodError, ActiveRecord::RecordNotFound
    nil
  end
end
