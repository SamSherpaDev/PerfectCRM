class Mail::ImportJob < ApplicationJob
  queue_as :default
  limits_concurrency to: 1, key: ->(id) { "mail-import-#{id}" }

  def perform(mail_import_id, fetcher: nil)
    mail_import = ::MailImport.find(mail_import_id)
    return if mail_import.done?

    mail_import.update!(status: "running", started_at: mail_import.started_at || Time.current, error: nil)
    fetcher ||= Mail::ImapFetcher.new
    progress = mail_import.preview_json || {}
    choices = progress.fetch("choices", {})
    fetcher.fetch_all(since: mail_import.cutoff_date&.to_time, after_uid: progress["import_uid"],
      uid_validity: progress["import_validity"], on_mailbox: ->(validity) {
        if progress["import_validity"] != validity
          progress = progress.merge("import_uid" => 0, "import_validity" => validity)
          mail_import.update!(preview_json: progress, processed_messages: 0, linked_messages: 0, skipped_messages: 0)
        end
      }) do |item|
      mail_import.with_lock do
        parsed = Mail::Ingester.parse_raw(item.raw)
        result = Mail::Ingester.ingest(parsed: parsed, gmail: item.gmail)
        conversation = result[:conversation]
        apply_import_choice(conversation, parsed, choices, mail_import)
        linked = conversation&.linked?
        progress = progress.merge("import_uid" => item.uid, "import_validity" => item.uid_validity)
        mail_import.update!(preview_json: progress,
          processed_messages: mail_import.processed_messages + 1,
          linked_messages: mail_import.linked_messages + (linked ? 1 : 0),
          skipped_messages: mail_import.skipped_messages + (linked ? 0 : 1))
      end
    end
    mail_import.update!(status: "done", finished_at: Time.current)
  rescue StandardError => e
    mail_import&.update!(status: "failed", error: e.message.to_s.truncate(500))
    raise
  end

  private

  def apply_import_choice(conversation, parsed, choices, import)
    return if conversation.nil?

    counterparties = Mail.counterparties(parsed)
    counterparties.each do |sender|
      match = Mail::Matcher.call([ sender ])
      next if match.linkable || match.via == "ignored"

      kind = choices[sender]
      next unless %w[client organization lead].include?(kind)

      name = sender.split("@").first.to_s.split(/[._\-+]/).map(&:capitalize).join(" ").presence || sender
      record = case kind
      when "client"
        import.created_clients += 1
        ::Client.create!(name: name, email: sender, source: "email")
      when "organization"
        import.created_organizations += 1
        ::Organization.create!(name: name, email: sender, kind: "other")
      when "lead"
        ::Lead.create!(name: name, email: sender, source: "email")
      end
      ::EmailIdentity.remember!(sender, linkable: record)
    end
    return if conversation.linked? || conversation.ignored?

    match = Mail::Matcher.call(counterparties)
    conversation.update!(linkable: match.linkable) if match.linkable
  end
end
