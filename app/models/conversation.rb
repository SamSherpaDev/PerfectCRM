class Conversation < ApplicationRecord
  belongs_to :linkable, polymorphic: true, optional: true
  has_many :messages, -> { order(sent_at: :desc, id: :desc) }, dependent: :destroy, inverse_of: :conversation

  serialize :participant_emails, coder: JSON

  after_update :touch_linkable!, if: -> { saved_change_to_linkable_id? || saved_change_to_linkable_type? }

  validates :unread_count, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :ai_triage, inclusion: { in: %w[new_inquiry returning_client operator vendor_or_spam other], allow_nil: true }

  scope :ordered, -> { order(Arel.sql("COALESCE(conversations.last_message_at, conversations.updated_at) DESC, conversations.id DESC")) }
  scope :linked, -> { where.not(linkable_type: nil) }
  scope :triage, -> { where(linkable_type: nil, ignored: false) }
  scope :sensitive_documents, -> {
    where(id: joins(messages: { files_attachments: :blob })
      .where("json_extract(active_storage_blobs.metadata, '$.sensitive') = 1").select(:id))
  }
  scope :held_documents, -> { where(id: ::Message.where("json_array_length(held_attachments) > 0").select(:conversation_id)) }
  scope :needs_triage, -> { triage.or(sensitive_documents).or(held_documents) }
  scope :ignored_scope, -> { where(ignored: true) }

  # Reading a thread does not resolve waiting: only a later outbound message does.
  # An equal inbound/outbound timestamp remains in the waiting-on-you bucket.
  scope :waiting_on_you, -> {
    joins(:messages)
      .where(messages: { direction: "in" })
      .where("messages.sent_at >= COALESCE((SELECT MAX(m2.sent_at) FROM messages m2 WHERE m2.conversation_id = conversations.id AND m2.direction = 'out'), '1970-01-01')")
      .distinct
  }
  scope :waiting_on_them, -> {
    where.not(id: waiting_on_you.select(:id)).where.not(id: triage.select(:id))
  }

  def linked?
    linkable.present?
  end

  def triage?
    !linked? && !ignored?
  end

  def display_subject
    subject.presence || "(no subject)"
  end

  def other_participants
    Array(participant_emails).reject(&:blank?)
  end

  def waiting_on_you?
    last_in = messages.where(direction: "in").maximum(:sent_at)
    return false if last_in.nil?

    last_out = messages.where(direction: "out").maximum(:sent_at)
    last_out.nil? || last_in > last_out
  end

  def mark_read!
    now = Time.current
    messages.where(read_at: nil, direction: "in").update_all(read_at: now)
    update_columns(unread_count: 0, updated_at: Time.current)
  end

  def refresh_counters!
    count = messages.where(direction: "in", read_at: nil).count
    last_at = messages.maximum(:sent_at)
    update_columns(unread_count: count, last_message_at: last_at, updated_at: Time.current)
  end

  def touch_linkable!
    target = linkable
    if target.is_a?(Lead)
      at = messages.maximum(Arel.sql("COALESCE(sent_at, created_at)"))
      target.record_touch!(at: at) if at
    elsif target&.respond_to?(:touch_activity!)
      target.touch_activity!
    end
  end

  def linkable_name
    linkable.respond_to?(:name) ? linkable.name : nil
  end

  # Cached AI summary is stale once new mail lands; the next summarize
  # call rebuilds it.
  def expire_ai_caches!
    update_columns(ai_summary: nil, ai_summary_at: nil,
      ai_suggestion_title: nil, ai_suggestion_due_on: nil,
      ai_suggestion_reason: nil, ai_suggestion_at: nil)
  end

  def ai_enabled_for_linkable?
    linkable.nil? || !linkable.respond_to?(:ai_opt_out?) || !linkable.ai_opt_out?
  end
end
