require "mail"

# Turns one fetched email into Conversation + Message rows.
# Enforces the info@ hard rule, dedupes on X-GM-MSGID, threads on
# X-GM-THRID with a Message-ID/In-Reply-To/References fallback, stores
# attachments, and files the thread via Mail::Matcher (or triage).
module Mail
  class Ingester
    Parsed = Struct.new(:headers, :from_addresses, :to_addresses, :cc_addresses,
      :subject, :message_id, :in_reply_to, :references, :sent_at,
      :text_body, :html_body, :attachments, :raw_size, keyword_init: true)

    def self.ingest(parsed:, gmail:, **kwargs)
      new.ingest(parsed: parsed, gmail: gmail, **kwargs)
    end

    def ingest(parsed:, gmail:)
      gmail = gmail.transform_keys(&:to_sym)
      gm_message_id = gmail[:gm_msgid]&.to_s.presence
      gm_thread_id = gmail[:gm_thrid]&.to_s.presence
      labels = Array(gmail[:labels])

      return skipped(:filtered) unless Mail.keeps?(parsed.headers)

      existing = ::Message.find_by(gm_message_id: gm_message_id) if gm_message_id.present?
      existing ||= ::Message.find_by(message_id: parsed.message_id) if parsed.message_id.present?
      return { status: :duplicate, conversation: existing.conversation, message: existing } if existing

      uploaded = []
      ::Message.transaction(requires_new: true) do |transaction|
        transaction.after_rollback { uploaded.each(&:delete) }
        conversation = find_conversation(gm_thread_id: gm_thread_id, parsed: parsed)
        direction = Mail.direction_for(parsed.from_addresses)

        message = conversation.messages.create!(
          direction: direction,
          gm_message_id: gm_message_id,
          message_id: parsed.message_id,
          in_reply_to: parsed.in_reply_to,
          references_text: parsed.references,
          from_address: parsed.from_addresses.first,
          to_addresses: parsed.to_addresses,
          cc_addresses: parsed.cc_addresses,
          subject: parsed.subject.presence || conversation.subject,
          text_body: parsed.text_body,
          html_body: parsed.html_body.present? ? Sanitizer.clean(parsed.html_body) : nil,
          sent_at: parsed.sent_at || Time.current,
          raw_size: parsed.raw_size.to_i,
          gmail_labels: labels
        )
        attach_files(message, parsed.attachments, uploaded)
        link_conversation(conversation, parsed)
        conversation.update!(
          subject: parsed.subject.presence || conversation.subject.presence || "(no subject)",
          participant_emails: participant_list(parsed),
          last_message_at: conversation.messages.maximum(:sent_at)
        )
        conversation.refresh_counters!
        { status: :stored, conversation: conversation, message: message }
      end
    end

    # Parses a raw RFC822 string into a Parsed struct. Used by the IMAP
    # fetcher and the import job; keeps parsing in one tested place.
    def self.parse_raw(raw)
      mail = ::Mail.read_from_string(raw.to_s)
      from = Array(mail.from).map { |value| value.to_s.downcase }
      to = Array(mail.to).map { |value| value.to_s.downcase }
      cc = Array(mail.cc).map { |value| value.to_s.downcase }
      text_body = nil
      html_body = nil
      attachments = []
      if mail.multipart?
        text_part = mail.text_part
        html_part = mail.html_part
        text_body = text_part&.decoded.to_s.presence
        html_body = html_part&.decoded.to_s.presence
        Array(mail.attachments).each do |part|
          attachments << {
            filename: part.filename.to_s.presence || "attachment",
            content_type: part.mime_type.to_s.presence || "application/octet-stream",
            data: part.body.decoded
          }
        end
      else
        if mail.mime_type == "text/html"
          html_body = mail.body.decoded.to_s
        else
          text_body = mail.body.decoded.to_s
        end
      end
      Parsed.new(
        headers: { "from" => from, "to" => to, "cc" => cc,
          "bcc" => Array(mail.bcc).map(&:downcase),
          "delivered-to" => mail.header.fields.select { |field| field.name.casecmp?("Delivered-To") }.map(&:value),
          "x-original-to" => mail.header.fields.select { |field| field.name.casecmp?("X-Original-To") }.map(&:value) },
        from_addresses: from, to_addresses: to, cc_addresses: cc,
        subject: mail.subject.to_s.strip.presence,
        message_id: mail.message_id.to_s.presence,
        in_reply_to: Array(mail.in_reply_to).first.to_s.presence,
        references: Array(mail.references).join(" ").presence,
        sent_at: mail.date&.to_time,
        text_body: text_body.to_s.presence,
        html_body: html_body.to_s.presence,
        attachments: attachments,
        raw_size: raw.to_s.bytesize
      )
    end

    private

    def skipped(reason)
      { status: reason, conversation: nil, message: nil }
    end

    def find_conversation(gm_thread_id:, parsed:)
      if gm_thread_id.present?
        found = ::Conversation.find_by(gm_thread_id: gm_thread_id)
        return found if found
      end
      # Fallback threading on reply headers when Gmail IDs are absent.
      if parsed.in_reply_to.present?
        found = ::Message.find_by(message_id: parsed.in_reply_to)&.conversation
        return found if found
      end
      Array(parsed.references.to_s.split).each do |ref|
        found = ::Message.find_by(message_id: ref)&.conversation
        return found if found
      end
      if parsed.message_id.present?
        found = ::Message.find_by(message_id: parsed.message_id)&.conversation
        return found if found
      end
      ::Conversation.create!(
        subject: parsed.subject.presence || "(no subject)",
        gm_thread_id: gm_thread_id.presence,
        participant_emails: participant_list(parsed),
        last_message_at: parsed.sent_at || Time.current
      )
    end

    def participant_list(parsed)
      (Array(parsed.from_addresses) + Array(parsed.to_addresses) + Array(parsed.cc_addresses))
        .map { |value| value.to_s.strip.downcase }.reject(&:blank?).uniq.first(20)
    end

    def attach_files(message, attachments, uploaded)
      skipped = []
      Array(attachments).each do |file|
        filename = file[:filename].to_s.presence || "attachment"
        content_type = file[:content_type].to_s.presence || "application/octet-stream"
        data = file[:data].to_s
        next if data.blank?
        if data.bytesize > 25.megabytes
          skipped << "#{filename}: skipped because it exceeds 25 MB."
          next
        end

        blob = ActiveStorage::Blob.build_after_unfurling(io: StringIO.new(data), filename: filename, content_type: content_type,
          metadata: { sensitive: ::Message.sensitive_attachment?(filename, content_type) })
        uploaded << blob
        blob.save!
        blob.upload_without_unfurling(StringIO.new(data))
        message.files.attach(blob)
      end
      message.update!(attachment_notices: skipped)
    end

    def link_conversation(conversation, parsed)
      return if conversation.linkable.present?

      counterparties = Mail.counterparties(parsed)
      match = Matcher.call(counterparties)
      if match.via == "ignored"
        conversation.update!(ignored: true)
        return
      end
      return if match.linkable.nil?

      conversation.update!(linkable: match.linkable)
      ::ActivityEvent.create!(
        subject: match.linkable, kind: "email",
        summary: "Email linked: #{conversation.display_subject}",
        occurred_at: Time.current,
        metadata: { "conversation_id" => conversation.id, "via" => match.via }
      )
    end
  end
end
