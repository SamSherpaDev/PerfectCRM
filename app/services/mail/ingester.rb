require "mail"

# Turns one fetched email into Conversation + Message rows.
# Enforces the info@ hard rule, dedupes on the provider message id
# (Graph id) and Message-ID, threads on the provider thread id (Graph
# conversationId) with a Message-ID/In-Reply-To/References fallback,
# stores attachments, and files the thread via Mail::Matcher (or triage).
module Mail
  class Ingester
    Parsed = Struct.new(:headers, :from_addresses, :to_addresses, :cc_addresses,
      :subject, :message_id, :in_reply_to, :references, :sent_at,
      :text_body, :html_body, :attachments, :raw_size, keyword_init: true)

    def self.ingest(parsed:, provider:, **kwargs)
      new.ingest(parsed: parsed, provider: provider, **kwargs)
    end

    # Commit cleanup keys before uploads and before any caller transaction
    # (including history import's lock), so rollback cannot orphan sensitive bytes.
    # Callers inside a transaction must pass preparations made beforehand.
    # Regression coverage: test/models/document_upload_orphan_test.rb.
    def self.prepare(parsed:)
      if DocumentUploadOrphan.connection.current_transaction.joinable?
        raise ActiveRecord::ActiveRecordError, "Prepare mail uploads before starting a transaction"
      end

      ordinary, held = partition_attachments(parsed.attachments)
      orphans = []
      DocumentUploadOrphan.transaction do
        held.each do |entry|
          next if entry["data"].bytesize > DocumentHolding::MAX_BYTES

          blob = ActiveStorage::Blob.build_after_unfurling(io: StringIO.new(entry["data"]),
            filename: entry["filename"], content_type: entry["content_type"])
          orphans << DocumentUploadOrphan.create!(key: blob.key, service_name: blob.service_name)
          entry["blob"] = blob
        end
      end
      [ ordinary, held, orphans ]
    end

    def ingest(parsed:, provider:, prepared: nil)
      provider = provider.transform_keys(&:to_sym)
      provider_message_id = provider[:message_id]&.to_s.presence
      thread_id = provider[:thread_id]&.to_s.presence
      labels = Array(provider[:labels])

      return skipped(:filtered) unless Mail.keeps?(parsed.headers)

      existing = ::Message.find_by(provider_message_id: provider_message_id) if provider_message_id.present?
      existing ||= ::Message.find_by(message_id: parsed.message_id) if parsed.message_id.present?
      return { status: :duplicate, conversation: existing.conversation, message: existing } if existing

      ordinary, held, orphans = prepared || self.class.prepare(parsed: parsed)
      uploaded = []
      ::Message.transaction(requires_new: true) do |transaction|
        orphans.each(&:claim!)
        transaction.after_commit { DocumentUploadOrphan.where(id: orphans.map(&:id)).delete_all }
        transaction.after_rollback { uploaded.each(&:delete) }
        conversation = find_conversation(thread_id: thread_id, parsed: parsed)
        direction = Mail.direction_for(parsed.from_addresses)

        message = conversation.messages.create!(
          direction: direction,
          provider_message_id: provider_message_id,
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
          provider_labels: labels
        )
        attach_files(message, ordinary, held, uploaded)
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

    # Parses a raw RFC822 string into a Parsed struct. Used by forward
    # screening and the remaining MIME paths; keeps parsing in one place.
    def self.parse_raw(raw)
      mail = ::Mail.read_from_string(raw.to_s)
      from = Array(mail.from).map { |value| value.to_s.downcase }
      to = Array(mail.to).map { |value| value.to_s.downcase }
      cc = Array(mail.cc).map { |value| value.to_s.downcase }
      text_body = nil
      html_body = nil
      attachments = []
      read_part = lambda do |part|
        disposition = part.content_disposition.to_s.split(";").first.to_s.strip
        if part.attachment? || disposition.casecmp?("attachment") || part.mime_type == "message/rfc822"
          attachments << {
            filename: part.filename.to_s.presence || "attachment",
            content_type: part.mime_type.to_s.presence || "application/octet-stream",
            data: part.body.decoded
          }
        elsif part.multipart?
          part.parts.each { |child| read_part.call(child) }
        elsif part.mime_type == "text/html"
          html_body ||= part.decoded.to_s.presence
        else
          text_body ||= part.decoded.to_s.presence
        end
      end
      read_part.call(mail)
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

    def find_conversation(thread_id:, parsed:)
      if thread_id.present?
        found = ::Conversation.find_by(provider_thread_id: thread_id)
        return found if found
      end
      # Fallback threading on reply headers when provider IDs are absent.
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
        provider_thread_id: thread_id.presence,
        participant_emails: participant_list(parsed),
        last_message_at: parsed.sent_at || Time.current
      )
    end

    def participant_list(parsed)
      (Array(parsed.from_addresses) + Array(parsed.to_addresses) + Array(parsed.cc_addresses) + Array(parsed.headers["bcc"]))
        .map { |value| value.to_s.strip.downcase }.reject(&:blank?).uniq
    end

    def self.partition_attachments(attachments)
      ordinary = []
      held = []
      Array(attachments).each do |file|
        filename = file[:filename].to_s.presence || "attachment"
        content_type = file[:content_type].to_s.presence || "application/octet-stream"
        data = file[:data].to_s
        next if data.blank?

        # A reader can mark an entry sensitive when it could not screen
        # everything inside it (see GraphFetcher#forwarded_entry); such
        # bytes are held rather than offered as a download.
        if file[:sensitive] || ::Message.sensitive_attachment?(filename, content_type, data: data)
          held << { "filename" => filename, "byte_size" => data.bytesize, "content_type" => content_type,
            "data" => data, "status" => "held: send to PerfectBook" }
        elsif content_type == "message/rfc822" || filename.downcase.end_with?(".eml")
          enclosed, sensitive = partition_attachments(parse_raw(data).attachments)
          if sensitive.any?
            ordinary.concat(enclosed)
            held.concat(sensitive)
          else
            ordinary << { filename: filename, content_type: content_type, data: data }
          end
        else
          ordinary << { filename: filename, content_type: content_type, data: data }
        end
      end
      [ ordinary, held ]
    end

    def attach_files(message, ordinary, held, uploaded)
      skipped = []
      ordinary.each do |file|
        filename = file[:filename]
        content_type = file[:content_type]
        data = file[:data]
        if data.bytesize > 25.megabytes
          skipped << "#{filename}: skipped because it exceeds 25 MB."
          next
        end

        blob = ActiveStorage::Blob.build_after_unfurling(io: StringIO.new(data), filename: filename, content_type: content_type)
        uploaded << blob
        blob.save!
        blob.upload_without_unfurling(StringIO.new(data))
        message.files.attach(blob)
      end
      placeholders = held.map do |entry|
        # In-memory bytes only: stripped before the JSON column is saved.
        data = entry.delete("data").to_s
        blob = entry.delete("blob")
        if data.bytesize > DocumentHolding::MAX_BYTES
          entry.merge("status" => "held: too large for the PerfectBook hand-off (10 MB max)")
        else
          holding = DocumentHolding.create!(message: message, filename: entry["filename"],
            content_type: entry["content_type"], byte_size: data.bytesize,
            expires_at: DocumentHolding::HOLD_HOURS.hours.from_now)
          uploaded << blob
          blob.save!
          blob.upload_without_unfurling(StringIO.new(data))
          holding.file.attach(blob)
          entry.merge("holding_id" => holding.id)
        end
      end
      message.update!(attachment_notices: skipped, held_attachments: placeholders)
      if placeholders.any?
        ::Note.create!(notable: message.conversation,
          body: "Sensitive documents arrived with message #{message.id} and wait in the 24-hour holding area. Send each to PerfectBook from the thread; unclaimed files purge automatically.")
      end
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
