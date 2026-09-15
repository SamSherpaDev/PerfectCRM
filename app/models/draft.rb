# The captain's unsent reply: one per conversation (a reply) or per owner
# (a new message). Sending never auto-fires from here; the draft survives a
# failed delivery so no words are ever lost.
class Draft < ApplicationRecord
  belongs_to :owner, polymorphic: true
  belongs_to :conversation, optional: true
  belongs_to :template, optional: true
  has_many_attached :files

  validates :owner_type, inclusion: { in: Conversation::OWNER_TYPES }

  def self.for_owner(owner, conversation: nil)
    if conversation
      conversation.draft || conversation.build_draft(owner: owner)
    else
      where(owner: owner, conversation_id: nil).first || new(owner: owner)
    end
  end

  def attach_uploads(uploads)
    uploads = uploads.values if uploads.is_a?(Hash)
    Array(uploads).compact_blank.each { |upload| files.attach(upload) }
  end

  def empty?
    [ to_addrs, cc_addrs, bcc_addrs, subject, body ].all?(&:blank?) &&
      template_id.nil? && perfectbook_booking_id.nil? && !files.attached?
  end
end
