class Message < ApplicationRecord
  DIRECTIONS = %w[in out].freeze

  belongs_to :conversation, inverse_of: :messages, optional: true
  alias_attribute :references, :references_text

  STATUSES = %w[queued sending sent failed received].freeze

  belongs_to :group_send, optional: true
  belongs_to :template, optional: true

  validates :status, inclusion: { in: STATUSES }
  validates :to_addrs, presence: true, if: :outbound?
  validates :subject, presence: true, if: :outbound?
  validates :text_body, presence: true, if: :outbound?
  validate :needs_a_home

  scope :for_owner, ->(owner) {
    joins(:conversation)
      .where(conversations: { linkable_type: owner.class.name, linkable_id: owner.id })
  }
  scope :newest_first, -> { order(Arel.sql("COALESCE(messages.sent_at, messages.created_at) DESC, messages.id DESC")) }
  scope :for_timeline, -> { outbound.where(status: %w[queued sending sent failed]) }


  has_many_attached :files

  serialize :to_addresses, coder: JSON
  serialize :cc_addresses, coder: JSON
  serialize :gmail_labels, coder: JSON
  serialize :attachment_notices, coder: JSON
  serialize :held_attachments, coder: JSON

  validates :direction, inclusion: { in: DIRECTIONS }
  validates :gm_message_id, uniqueness: { allow_nil: true }

  scope :inbound, -> { where(direction: "in") }
  scope :outbound, -> { where(direction: "out") }
  scope :unread, -> { where(direction: "in", read_at: nil) }
  scope :oldest_first, -> { order(sent_at: :asc, id: :asc) }

  after_create :bump_conversation
  after_destroy :rebalance_conversation

  def self.sensitive_attachment?(filename, content_type, data: nil)
    pattern = /passport|visa|insurance|identity|(?:\A|[^a-z])(?:id|dob)(?:[^a-z]|\z)|birth|scan/i
    return true if "#{filename} #{content_type}".match?(pattern)
    return false unless data && (content_type == "application/pdf" || filename.downcase.end_with?(".pdf") || data.start_with?("%PDF-"))

    PDF::Reader.new(StringIO.new(data)).info[:Title].to_s.match?(pattern)
  rescue PDF::Reader::MalformedPDFError, PDF::Reader::UnsupportedFeatureError
    true
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
    conversation&.refresh_counters!
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

  def sent?
    status == "sent"
  end

  def failed?
    status == "failed"
  end

  def to_addrs
    to_list.join(", ")
  end

  def to_addrs=(value)
    self.to_addresses = value.to_s.split(",").map(&:strip).reject(&:blank?)
  end

  def cc_addrs
    cc_list.join(", ")
  end

  def cc_addrs=(value)
    self.cc_addresses = value.to_s.split(",").map(&:strip).reject(&:blank?)
  end

  def recipients
    to_addrs.to_s.split(/[,\n;]/).map(&:strip).reject(&:blank?)
  end

  def mark_sending!
    claimed = self.class.where(id: id, direction: "outbound", status: "queued")
      .update_all(status: "sending", send_error: nil, updated_at: Time.current)
    return false unless claimed == 1

    reload
    true
  end

  def mark_sent!
    transaction do
      update!(status: "sent", sent_at: Time.current, send_error: nil)
      conversation&.touch_activity!
      draft = Draft.find_by(id: submitted_draft_id)
      draft&.with_lock do
        draft.destroy! if draft.updated_at == submitted_draft_updated_at
      end
      owner&.touch_activity!
    end
  end

  def mark_failed!(error)
    update!(status: "failed", send_error: error.to_s.truncate(500))
  end

  # The record whose timeline carries this message, via its conversation.
  def owner
    conversation&.owner
  end


  private
  def needs_a_home
    if conversation.nil? && group_send.nil?
      errors.add(:conversation, "or group send must be present")
    end
  end

  def bump_conversation
    conversation&.refresh_counters!
    conversation.expire_ai_caches! if conversation&.has_attribute?(:ai_summary)
    conversation&.touch_linkable!
  rescue ActiveRecord::RecordNotFound
    nil
  end

  def rebalance_conversation
    conversation&.refresh_counters!
  rescue ActiveRecord::RecordNotFound
    nil
  end
end
