class Mail::ImportJob < ApplicationJob
  queue_as :default
  limits_concurrency to: 1, key: ->(id) { "mail-import-#{id}" }

  def perform(mail_import_id, fetcher: nil)
    mail_import = ::MailImport.find(mail_import_id)
    return if mail_import.done?

    mail_import.update!(status: "running", started_at: mail_import.started_at || Time.current, error: nil)
    fetcher ||= Mail::GraphFetcher.new
    progress = mail_import.preview_json || {}
    choices = progress.fetch("choices", {})
    fetcher.fetch_history(since: mail_import.cutoff_date&.to_time, cursor: progress["history_cursor"]) do |item|
      parsed = item.parsed
      prepared = Mail::Ingester.prepare(parsed: parsed)
      mail_import.with_lock do
        result = Mail::Ingester.ingest(parsed: parsed, provider: item.provider, prepared: prepared)
        conversation = result[:conversation]
        apply_import_choice(conversation, parsed, choices, mail_import)
        # Only newly stored mail counts. A resume replays the cursor's whole
        # second and the CRM may already hold the message from live sync;
        # either way that work is done, and counting it again would show
        # the captain more imported than the preview ever found.
        stored = result[:status] == :stored
        linked = stored && conversation&.linked?
        progress = progress.merge("history_cursor" => item.cursor)
        mail_import.update!(preview_json: progress,
          processed_messages: mail_import.processed_messages + (stored ? 1 : 0),
          linked_messages: mail_import.linked_messages + (linked ? 1 : 0),
          skipped_messages: mail_import.skipped_messages + (stored && !linked ? 1 : 0))
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
