# frozen_string_literal: true

# Queues correspondence without delivering inside the request transaction.
# OutboundDeliveryJob delivers the persisted message; ClientMailer renders it.
module Outbound
  class Composer
    def self.call(owner:, params:, conversation: nil, group_send: nil)
      Message.transaction { new(owner, params, conversation, group_send).compose }
    end

    # The From/Reply-To identity for every CRM send. MAIL_FROM carries the
    # mailbox (info@sherpaholidays.com on Microsoft 365); the sender
    # name comes from Settings.
    def self.from_address
      ENV.fetch("MAIL_FROM", "info@sherpaholidays.com").strip.presence ||
        "info@sherpaholidays.com"
    end

    def self.from_display
      address = ::Mail::Address.new(from_address)
      address.display_name = Setting.current.sender_name.presence
      address.format
    end

    def initialize(owner, params, conversation, group_send)
      @owner = owner
      @params = params
      @conversation = conversation
      @group_send = group_send
    end

    def compose
      message = build
      message.save!
      @params[:template_id].present? && Template.where(id: @params[:template_id]).first&.record_use!
      message
    end

    def build
      @owner.reload if @owner&.persisted?
      @draft = Draft.for_owner(@owner, conversation: @conversation) if @owner && !@group_send
      resolve_conversation
      message = @conversation ? @conversation.messages.build : Message.new
      message.submitted_draft_id = @draft.id if @draft&.persisted?
      message.submitted_draft_updated_at = @draft.updated_at if @draft&.persisted?
      message.group_send = @group_send if @group_send
      message.direction = "out"
      message.status = "queued"
      message.from_address = self.class.from_address
      to = recipients
      cc = EmailRedirects.mailboxes(@params[:cc])
      bcc = EmailRedirects.mailboxes(@params[:bcc])
      confirm_recipients!(message, to + cc + bcc)
      message.to_addrs = redirect_explicit(to).join(", ")
      message.cc_addrs = redirect_explicit(cc).join(", ")
      message.bcc_addrs = redirect_explicit(bcc).join(", ")
      message.subject = @params[:subject].to_s.strip.presence || default_subject
      if @params[:body].to_s.strip.blank?
        message.errors.add(:text_body, :blank)
        raise ActiveRecord::RecordInvalid, message
      end
      message.text_body = with_signature(@params[:body].to_s.gsub("\r\n", "\n"))
      message.html_body = nil
      message.template_id = @params[:template_id].presence
      thread_under_parent(message)
      message.message_id ||= "#{SecureRandom.uuid}@#{domain}"
      attach_files(message)
      message.validate!
      message
    rescue ::Mail::Field::ParseError
      message.errors.add(:base, "Enter valid recipient email addresses.")
      raise ActiveRecord::RecordInvalid, message
    end

    private

    def confirm_recipients!(message, addresses)
      return unless @owner.respond_to?(:ambiguous_recipient_emails)

      addresses |= @owner.resolve_redirected_list(addresses.join(", "))
      ambiguous = addresses & @owner.ambiguous_recipient_emails
      if (ambiguous - @owner.current_recipient_emails).any?
        message.errors.add(:base, "Choose a current recipient in place of the reassigned address before sending.")
        raise ActiveRecord::RecordInvalid, message
      end
      confirmation = @params[:recipient_confirmation]
      return if ambiguous.empty? && confirmation.blank?
      return if @owner.recipient_confirmation_valid?(confirmation)

      message.errors.add(:base, "Review To, Cc and Bcc and confirm the current recipients. An address was reassigned or restored.")
      raise ActiveRecord::RecordInvalid, message
    end

    def resolve_conversation
      return if @conversation
      return if @owner.nil?

      subject = @params[:subject].to_s.strip
      @conversation = @owner.conversations.build(subject_line: subject.presence || default_subject)
    end

    # Corrections apply to drafts and future sends. An already-queued
    # send keeps the envelope stored when Send was pressed; past messages
    # keep their attribution and are never rewritten.
    def recipients
      explicit = EmailRedirects.mailboxes(@params[:to])
      if explicit.any?
        return explicit
      end
      return [] if @owner.nil?

      if @conversation&.thread_parent
        return EmailRedirects.mailboxes(@conversation.thread_parent.recipients.join(", "))
      end

      Array(@owner.try(:display_email) || @owner.try(:email)).compact_blank
    end

    def redirect_explicit(list)
      return list unless @owner.respond_to?(:resolve_redirected_list)

      @owner.resolve_redirected_list(list.join(", "))
    end

    def default_subject
      parent = @conversation&.thread_parent
      parent_subject = parent&.subject.presence || @conversation&.subject_line.presence
      return "Hello from Sherpa Holidays" if parent_subject.blank?

      parent ? "Re: #{parent_subject.sub(/\ARe:\s*/i, '')}" : parent_subject
    end

    def with_signature(body)
      return body if EmailSignature.template_carries_signature?(@params[:template_id])

      signature = EmailSignature.text_for(Setting.current).presence
      return body if signature.blank?

      stripped = body.rstrip
      return body if stripped.end_with?(signature.strip)

      "#{stripped}\n\n#{signature.strip}\n"
    end

    def thread_under_parent(message)
      parent = @conversation&.thread_parent
      return if parent.nil?

      message.in_reply_to = parent.message_id
      prior = parent.references.to_s.split
      message.references = ([ *prior, parent.message_id ]).uniq.join(" ")
    end

    def domain
      self.class.from_address.split("@").last.presence || "sherpaholidays.com"
    end

    def attach_files(message)
      files = @params[:files]
      files = files.values if files.is_a?(Hash)
      uploads = Array(files).compact_blank
      uploads += @draft.files.blobs.to_a if @draft&.files&.attached?
      allowed, refused = Uploads.partition(uploads)
      raise Uploads::SensitiveDocument if refused.any?

      allowed.each { |file| message.files.attach(file) }
    end
  end
end
