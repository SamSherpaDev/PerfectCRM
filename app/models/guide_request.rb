# Fulfillment permission only. No Person/Lead/Shopify record or marketing state.
class GuideRequest < ApplicationRecord
  belongs_to :message, optional: true
  normalizes :email, with: ->(value) { value.to_s.strip.downcase }
  validates :email, :edition, :source, presence: true

  def self.accept!(email:, source:)
    raise PrivateNepalGuide::Unavailable unless PrivateNepalGuide.available?

    transaction do
      receipt = create_or_find_by!(email: email, edition: PrivateNepalGuide::EDITION) { |row| row.source = source }
      receipt.with_lock do
        unless receipt.message_id
          content = PrivateNepalGuide.content
          # An unlinked mail thread allows normal info@ replies without making
          # an inquiry, looking up contacts, consuming drafts or adding a signature.
          conversation = Conversation.create!(subject: content[:subject], participant_emails: [ email ])
          message = conversation.messages.create!(direction: "out", status: "queued",
            from_address: PrivateNepalGuide::FROM, to_addresses: [ email ],
            subject: content[:subject], text_body: content[:body],
            message_id: "#{SecureRandom.uuid}@sherpaholidays.com")
          receipt.update!(message: message)
        end
      end
      receipt
    end
  end

  def enqueue_delivery!
    return unless delivery_attempted_at.nil? && message&.status == "queued"
    raise PrivateNepalGuide::Unavailable unless OutboundDeliveryJob.perform_later(message_id)
  end

  # Same outbox recovery convention as LeadNotification, without replaying
  # failed/uncertain sends. Multiple queued jobs still share one durable claim.
  def self.enqueue_pending
    return unless PrivateNepalGuide.available?

    where(delivery_attempted_at: nil).joins(:message).where(messages: { status: "queued" }).find_each(&:enqueue_delivery!)
  end

  def claim_delivery!
    self.class.where(id: id, delivery_attempted_at: nil).update_all(delivery_attempted_at: Time.current) == 1
  end

  def delivery_allowed?
    return true if PrivateNepalGuide.available?

    message.mark_failed!("Guide fulfillment unavailable; no automatic retry.")
    false
  end
end
